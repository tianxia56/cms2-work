#!/usr/bin/env python3

"""Deploy WDL to Terra.
"""

import argparse
import csv
import collections
import concurrent.futures
import contextlib
import copy
import functools
import glob
import gzip
import io
import json
import logging
import multiprocessing
import operator
import os
import os.path
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

#print(fiss.meth_list(args=argparse.Namespace()))
import firecloud.api as fapi

# * Utils

_log = logging.getLogger(__name__)
logging.basicConfig(level=logging.DEBUG,
                    format='%(asctime)s %(levelname)s %(message)s')

MAX_INT32 = (2 ** 31)-1

def dump_file(fname, value):
    """store string in file"""
    with open(fname, 'w')  as out:
        out.write(str(value))

def _pretty_print_json(json_val, sort_keys=True):
    """Return a pretty-printed version of a dict converted to json, as a string."""
    return json.dumps(json_val, indent=4, separators=(',', ': '), sort_keys=sort_keys)

def _write_json(fname, json_val):
    dump_file(fname=fname, value=_pretty_print_json(json_val))

def _load_dict_sorted(d):
    return collections.OrderedDict(sorted(d.items()))

def _json_loads(s):
    return json.loads(s.strip(), object_hook=_load_dict_sorted, object_pairs_hook=collections.OrderedDict)

def _json_loadf(fname):
    return _json_loads(slurp_file(fname))

def slurp_file(fname, maxSizeMb=50):
    """Read entire file into one string.  If file is gzipped, uncompress it on-the-fly.  If file is larger
    than `maxSizeMb` megabytes, throw an error; this is to encourage proper use of iterators for reading
    large files.  If `maxSizeMb` is None or 0, file size is unlimited."""
    fileSize = os.path.getsize(fname)
    if maxSizeMb  and  fileSize > maxSizeMb*1024*1024:
        raise RuntimeError('Tried to slurp large file {} (size={}); are you sure?  Increase `maxSizeMb` param if yes'.
                           format(fname, fileSize))
    with open_or_gzopen(fname) as f:
        return f.read()

def open_or_gzopen(fname, *opts, **kwargs):
    mode = 'r'
    open_opts = list(opts)
    assert type(mode) == str, "open mode must be of type str"

    # 'U' mode is deprecated in py3 and may be unsupported in future versions,
    # so use newline=None when 'U' is specified
    if len(open_opts) > 0:
        mode = open_opts[0]
        if sys.version_info[0] == 3:
            if 'U' in mode:
                if 'newline' not in kwargs:
                    kwargs['newline'] = None
                open_opts[0] = mode.replace("U","")

    # if this is a gzip file
    if fname.endswith('.gz'):
        # if text read mode is desired (by spec or default)
        if ('b' not in mode) and (len(open_opts)==0 or 'r' in mode):
            # if python 2
            if sys.version_info[0] == 2:
                # gzip.open() under py2 does not support universal newlines
                # so we need to wrap it with something that does
                # By ignoring errors in BufferedReader, errors should be handled by TextIoWrapper
                return io.TextIOWrapper(io.BufferedReader(gzip.open(fname)))

        # if 't' for text mode is not explicitly included,
        # replace "U" with "t" since under gzip "rb" is the
        # default and "U" depends on "rt"
        gz_mode = str(mode).replace("U","" if "t" in mode else "t")
        gz_opts = [gz_mode]+list(opts)[1:]
        return gzip.open(fname, *gz_opts, **kwargs)
    else:
        return open(fname, *open_opts, **kwargs)

def available_cpu_count():
    """
    Return the number of available virtual or physical CPUs on this system.
    The number of available CPUs can be smaller than the total number of CPUs
    when the cpuset(7) mechanism is in use, as is the case on some cluster
    systems.

    Adapted from http://stackoverflow.com/a/1006301/715090
    """

    cgroup_cpus = MAX_INT32
    try:
        def get_cpu_val(name):
            return float(slurp_file('/sys/fs/cgroup/cpu/cpu.'+name).strip())
        cfs_quota = get_cpu_val('cfs_quota_us')
        if cfs_quota > 0:
            cfs_period = get_cpu_val('cfs_period_us')
            _log.debug('cfs_quota %s, cfs_period %s', cfs_quota, cfs_period)
            cgroup_cpus = max(1, int(cfs_quota / cfs_period))
    except Exception as e:
        pass

    proc_cpus = MAX_INT32
    try:
        with open('/proc/self/status') as f:
            status = f.read()
        m = re.search(r'(?m)^Cpus_allowed:\s*(.*)$', status)
        if m:
            res = bin(int(m.group(1).replace(',', ''), 16)).count('1')
            if res > 0:
                proc_cpus = res
    except IOError:
        pass

    _log.debug('cgroup_cpus %d, proc_cpus %d, multiprocessing cpus %d',
               cgroup_cpus, proc_cpus, multiprocessing.cpu_count())
    return min(cgroup_cpus, proc_cpus, multiprocessing.cpu_count())

def execute(action, **kw):
    succeeded = False
    try:
        _log.debug('Running command: %s', action)
        subprocess.check_call(action, shell=True, **kw)
        succeeded = True
    finally:
        _log.debug('Returned from running command: succeeded=%s, command=%s', succeeded, action)

SEL_NAMESPACE='tianxia'
SEL_WORKSPACE='cms2'
TERRA_METHOD_NAME='test-cosi2-method-01'
TERRA_CONFIG_NAME='dockstore-tool-cms2'
TERRA_GS_BUCKET='fc-97de97ff-f4ee-414a-bf2d-a5f045b20a79'
TRAVIS_COMMIT=os.environ['TRAVIS_COMMIT']
TRAVIS_BRANCH=os.environ['TRAVIS_BRANCH']
TRAVIS_REPO_SLUG=os.environ['TRAVIS_REPO_SLUG']
STAGING_TRAVIS_REPO_SLUG='notestaff/cms2-staging'
STAGING_BRANCH=f'staging-{TRAVIS_BRANCH}--{TRAVIS_COMMIT}'
GITHUB_REPO=TRAVIS_REPO_SLUG.split('/')[1]

TERRA_DEST=f'gs://{TERRA_GS_BUCKET}/{GITHUB_REPO}/{TRAVIS_BRANCH}/{TRAVIS_COMMIT}/'
GH_TOKEN=os.environ['GH_TOKEN']

for wdl_fname in glob.glob('*.wdl'):
    wdl = slurp_file(wdl_fname)
    wdl_repl = re.sub(r'import "./([^"]+)"',
                      f'import "https://raw.githubusercontent.com/{STAGING_TRAVIS_REPO_SLUG}/{STAGING_BRANCH}/\\1"',
                      wdl, flags=re.MULTILINE)
    if wdl_repl != wdl:
        print('Replaced in file', wdl_fname)
        dump_file(wdl_fname, wdl_repl)

execute(f'sed -i "s#\\"./#\\"{TERRA_DEST}#g" *.wdl *.wdl.json')
execute(f'gsutil -m cp *.py *.wdl *.cosiParams *.par *.recom {TERRA_DEST}')
execute('git config --global user.email "travis@travis-ci.org"')
execute('git config --global user.name "Travis CI"')
execute('git status')
execute(f'git checkout -b {STAGING_BRANCH}')
execute(f'git add .')
execute('git status')
execute(f'git commit -m "created staging branch {STAGING_BRANCH}"')

execute(f'git remote rm origin-staging || true')
execute(f'git remote add origin-staging "https://{GH_TOKEN}@github.com/{STAGING_TRAVIS_REPO_SLUG}.git"')
execute(f'git push --set-upstream origin-staging {STAGING_BRANCH}')

#dir(fapi)
#help(fapi)
#z = fapi.list_workspace_configs(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, allRepos=True).json()
#print('LIST_WORKSPACE_CONFIGS result is', z)
#z = fapi.get_workspace_config(workspace=SEL_WORKSPACE, namespace=SEL_NAMESPACE,
#                              config=TERRA_CONFIG_NAME, cnamespace=SEL_NAMESPACE)

#print('CONFIG_IS', z, z.json())

#z = fapi.list_repository_methods(namespace=SEL_NAMESPACE, name=TERRA_METHOD_NAME).json()
#print('METHODS LIST BEF', z)

z = fapi.update_repository_method(namespace=SEL_NAMESPACE, method=TERRA_METHOD_NAME, synopsis='run sims and compute component stats',
                                  wdl=os.path.abspath(f'./Dockstore.wdl'))
#print('UPDATE IS', z, z.json())
new_method = z.json()
print('NEW_METHOD IS', new_method)

#z = fapi.list_repository_methods(namespace=SEL_NAMESPACE, name=TERRA_METHOD_NAME).json()
#print('METHODS LIST AFT', z)

snapshot_id = new_method['snapshotId']

z = fapi.get_repository_method_acl(namespace=SEL_NAMESPACE, method=TERRA_METHOD_NAME, snapshot_id=snapshot_id)
print('ACL:', z, z.json())

z = fapi.update_repository_method_acl(namespace=SEL_NAMESPACE, method=TERRA_METHOD_NAME, snapshot_id=snapshot_id,
                                      acl_updates=[{'role': 'OWNER', 'user': 'sgosai@broadinstitute.org'},
                                                   {'role': 'OWNER', 'user': 'sreilly@broadinstitute.org'}])
print('ACL UPDATE:', z, z.json())
z = fapi.get_repository_method_acl(namespace=SEL_NAMESPACE, method=TERRA_METHOD_NAME, snapshot_id=snapshot_id)
print('ACL AFTER UPDATE:', z, z.json())

z = fapi.get_config_template(namespace=SEL_NAMESPACE, method=TERRA_METHOD_NAME, version=snapshot_id)
#print('CONFIG TEMPLATE AFT IS', z, z.json())
config_template = z.json()

#z = fapi.list_workspace_configs(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, allRepos=True).json()
#print('LIST_WORKSPACE_CONFIGS allRepos', z)
TERRA_CONFIG_NAME += f'_cfg_{snapshot_id}' 
# z = fapi.get_workspace_config(workspace=SEL_WORKSPACE, namespace=SEL_NAMESPACE,
#                               config=TERRA_CONFIG_NAME, cnamespace=SEL_NAMESPACE)

# print('WORKSPACE_CONFIG_NOW_IS', z, z.json())

inputs = dict(_json_loadf(f'./test.02.wdl.json'))

config_json = copy.copy(config_template)
#print('CONFIG_JSON before deleting rootEntityType', config_json)
#del config_json['rootEntityType']
#print('CONFIG_JSON after deleting rootEntityType', config_json)
#print('CONFIG_JSON about to be updated with inputs:', inputs)
#config_json.update(namespace=SEL_NAMESPACE, name=TERRA_METHOD_NAME, inputs=inputs, outputs={})
#print('CONFIG_JSON AFTER UPDATING with inputs:', config_json)


# orig_template = copy.copy(config_template)
# print('ORIG_TEMPLATE is', orig_template)
# del orig_template['rootEntityType']
# z = fapi.create_workspace_config(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, body=orig_template)
# print('CREATED CONFIG WITH ORIG TEMPLATE:', z, z.json())
print('methodConfigVersion was', config_json['methodConfigVersion'])
config_json['methodConfigVersion'] = snapshot_id
print('methodConfigVersion now is', config_json['methodConfigVersion'])
config_json['namespace'] = SEL_NAMESPACE   # configuration namespace
config_json['name'] = TERRA_CONFIG_NAME
if 'rootEntityType' in config_json:
    del config_json['rootEntityType']
config_json['inputs'].update(inputs)

print('AFTER UPDATING METHODCONFIGVERSION config_json is', config_json)

z = fapi.create_workspace_config(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, body=config_json)
print('CREATED CONFIG WITH OUR INPUTS:', z, z.json())

z = fapi.validate_config(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, cnamespace=SEL_NAMESPACE, config=TERRA_CONFIG_NAME)
print('VALIDATE_CONFIG:', z, z.json())

z = fapi.get_repository_config_acl(namespace=SEL_NAMESPACE, config=TERRA_CONFIG_NAME, snapshot_id=1)
print('REPO CONFIG ACL:', z, z.json())

z = fapi.get_workspace_acl(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE)
print('WORKSPACE ACL:', z, z.json())


# z = fapi.overwrite_workspace_config(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE,
#                                     cnamespace=SEL_NAMESPACE, configname=TERRA_CONFIG_NAME, body=config_json)
# print('OVERWROTE', z, z.json())

z = fapi.get_workspace_config(workspace=SEL_WORKSPACE, namespace=SEL_NAMESPACE,
                              config=TERRA_CONFIG_NAME, cnamespace=SEL_NAMESPACE)

print('CONFIG_NOW_IS_2', z, z.json())


if True:
    z = fapi.create_submission(wnamespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE,
                               cnamespace=SEL_NAMESPACE, config=TERRA_CONFIG_NAME)
    print('SUBMISSION IS', z, z.json())

# sys.exit(0)

# def dump_file(fname, value):
#     """store string in file"""
#     with open(fname, 'w')  as out:
#         out.write(str(value))

# #z = fapi.create_submission(wnamespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE,
# #                           cnamespace=SEL_NAMESPACE, config=TERRA_CONFIG_NAME)
# #print('SUBMISSION IS', z, z.json())

# #z = fapi.get_config_template(namespace='dockstore', method=TERRA_CONFIG_NAME, version=1)
# #print(z.json())

# def _pretty_print_json(json_dict, sort_keys=True):
#     """Return a pretty-printed version of a dict converted to json, as a string."""
#     return json.dumps(json_dict, indent=4, separators=(',', ': '), sort_keys=sort_keys)

# def _write_json(fname, **json_dict):
#     dump_file(fname=fname, value=_pretty_print_json(json_dict))



# #print('ENTITIES ARE', fapi.list_entity_types(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE).json())
# z = fapi.list_submissions(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE)
# #print('SUBMISSIONS ARE', z, z.json())
# for s in sorted(list(z.json()), key=operator.itemgetter('submissionDate'), reverse=True)[:1]:
#     #if not s['submissionDate'].startswith('2020-06-29'): continue

#     print('====================================================')
#     print(s)
#     y = fapi.get_submission(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, submission_id=s['submissionId']).json()

#     zz = fapi.get_workflow_metadata(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, submission_id=s['submissionId'],
#                                     workflow_id=y['workflows'][0]['workflowId']).json()
#     _write_json('tmp/j2.json', **zz)
#     dump_file(fname='tmp/w.wdl', value=zz['submittedFiles']['workflow'])

#     # zzz = fapi.get_workflow_metadata(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, submission_id=s['submissionId'],
#     #                                 workflow_id='ad1e8271-fe66-4e05-9005-af570e9e5884').json()
#     # _write_json('tmp/jz.json', **zzz)














