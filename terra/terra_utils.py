#!/usr/bin/env python3

"""Utility commands for using Terra ( https://terra.bio/ )
"""

# * Preamble

import argparse
import csv
import collections
import collections.abc
import concurrent.futures
import contextlib
import copy
import datetime
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

# third-party imports
import yaml
import firecloud.api as fapi

# our imports
import misc_utils

_log = logging.getLogger(__name__)
logging.basicConfig(level=logging.DEBUG,
                    format='%(asctime)s %(levelname)s %(message)s')

# * Params/constants definitions

def quay_tag_exists(quay_tag, quay_repo, quay_token=os.environ['QUAY_CMS_TOKEN']):
    curl_cmd = f'curl -H "Authorization: Bearer {quay_token}" -X GET ' \
        f'"https://quay.io/api/v1/repository/{quay_repo}/tag/?specificTag={quay_tag}"'
    _log.debug(f'{curl_cmd=}')
    curl_out = subprocess.check_output(curl_cmd, shell=True).decode()
    curl_parsed = json.loads(curl_out.strip())
    _log.debug(f'{curl_parsed=}')
    return bool(curl_parsed['tags'])

def update_docker_images(quay_repo):

    docker_dirs = subprocess.check_output(f'git ls-tree HEAD:docker', shell=True).decode()
    docker_dir_to_docker_tag = {}

    misc_utils.execute('echo ${QUAY_ROBOT_TOKEN} | docker login -u="broad_cms_ci+broad_cms_ci_robot" --password-stdin quay.io')
    quay_logged_in = True

    for line in docker_dirs.strip().split('\n'):
        mode, git_obj_type, git_hash, docker_dir = line.strip().split()
        docker_dir_abs = os.path.realpath(os.path.join('docker', docker_dir))
        if git_obj_type in ('tree', 'commit') and os.path.isfile(os.path.join(docker_dir_abs, 'Dockerfile')):
            _log.debug(f'looking at {docker_dir} {git_hash}')
            docker_tag = f'{docker_dir}-{git_hash}'
            docker_tag_exists = quay_tag_exists(docker_tag, quay_repo=quay_repo)
            _log.debug(f'{docker_tag=} {docker_tag_exists=}')
            if not docker_tag_exists:
                pre_docker_script = os.path.join(docker_dir_abs, 'pre_docker.sh')
                if os.path.isfile(pre_docker_script):
                    misc_utils.execute(pre_docker_script, cwd=docker_dir_abs)

                misc_utils.execute(f'docker build -t quay.io/{quay_repo}:{docker_tag} .',
                                   cwd=docker_dir_abs)
                misc_utils.execute(f'docker push quay.io/{quay_repo}:{docker_tag}')
                misc_utils.chk(quay_tag_exists(docker_tag, quay_repo=quay_repo), f'{docker_tag=} still not in {quay_repo}!')
            docker_dir_to_docker_tag[docker_dir] = docker_tag
    return docker_dir_to_docker_tag

def do_update_wdl_dockers(quay_repo='broad_cms_ci/cms'):
    docker_dir_to_docker_tag = update_docker_images(quay_repo=quay_repo)

    for wdl_fname in glob.glob('*.wdl'):
        wdl = misc_utils.slurp_file(wdl_fname)
        wdl_repl = wdl

        for docker_dir, docker_tag in docker_dir_to_docker_tag.items():
            git_hash_re = '[0-9a-f]{40}'
            wdl_repl = re.sub(f'docker: "quay.io/{quay_repo}:{docker_dir}-{git_hash_re}"',
                              f'docker: "quay.io/{quay_repo}:{docker_tag}"',
                              wdl_repl, flags=re.MULTILINE)
        
        if wdl_repl != wdl:
            _log.debug(f'Replaced in file {wdl_fname}')
            misc_utils.dump_file(wdl_fname, wdl_repl)

def update_wdl_imports(staging_target):
    for wdl_fname in glob.glob('*.wdl'):
        wdl = misc_utils.slurp_file(wdl_fname)
        wdl_repl = re.sub(r'import "./([^"]+)"',
                          f'import "{staging_target}/\\1"',
                          wdl, flags=re.MULTILINE)
        if wdl_repl != wdl:
            _log.debug(f'Replaced in file {wdl_fname}')
            misc_utils.dump_file(wdl_fname, wdl_repl)

def customize_wdls_for_git_commit():
    """Upload files from this commit to the cloud, and create customized WDLs referencing this commit's version of files.   """

    TERRA_GS_BUCKET='fc-97de97ff-f4ee-414a-bf2d-a5f045b20a79'
    TRAVIS_COMMIT=os.environ['TRAVIS_COMMIT']
    TRAVIS_BRANCH=os.environ['TRAVIS_BRANCH']
    TRAVIS_REPO_SLUG=os.environ['TRAVIS_REPO_SLUG']
    STAGING_TRAVIS_REPO_SLUG='notestaff/cms2-staging'
    STAGING_BRANCH=f'staging-{TRAVIS_BRANCH}--{TRAVIS_COMMIT}'
    GITHUB_REPO=TRAVIS_REPO_SLUG.split('/')[1]

    TERRA_DEST=f'gs://{TERRA_GS_BUCKET}/{GITHUB_REPO}/{TRAVIS_BRANCH}/{TRAVIS_COMMIT}/'
    GH_TOKEN=os.environ['GH_TOKEN']

    do_update_wdl_dockers()

    update_wdl_imports(staging_target=f'https://raw.githubusercontent.com/{STAGING_TRAVIS_REPO_SLUG}/{STAGING_BRANCH}')

    execute = misc_utils.execute
    execute(f'sed -i "s#\\"./#\\"{TERRA_DEST}#g" *.wdl *.wdl.json')
    execute(f'gsutil -m cp *.py *.wdl *.cosiParams *.par *.recom *.test.bed {TERRA_DEST}')
    execute(f'gsutil -m cp resources/*.bed resources/*.json {TERRA_DEST}resources/')
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

# * def do_deploy_to_terra()
def do_deploy_to_terra(args):
    """Create Terra method and configuration for the workflow."""

    _log.debug(f'do_deploy_to_terra: {args=}')
    terra_config = misc_utils.load_config(args.config_file)['terra']
    _log.debug(f'{terra_config=}')

    SEL_NAMESPACE = terra_config['namespace']
    SEL_WORKSPACE = terra_config['workspace']
    for root_workflow_name, root_workflow_def in terra_config['root_workflows'].items():
        _log.debug(f'{root_workflow_name=} {root_workflow_def=}')
        if root_workflow_def.get('skip', False):
            _log.debug(f'skipping {root_workflow_name=} because of skip: True')
            continue
        TERRA_METHOD_NAME=root_workflow_def['method_name']
        TERRA_CONFIG_NAME=root_workflow_def['config_name']

        z = fapi.update_repository_method(namespace=SEL_NAMESPACE, method=TERRA_METHOD_NAME,
                                          synopsis=root_workflow_def['synopsis'],
                                          wdl=os.path.abspath(root_workflow_def['wdl']))
        
        def _log_json(heading, json_val):
            orig_val = ''
            if hasattr(json_val, 'json'):
                orig_val = str(json_val) + ' '
                json_val = json_val.json()
            _log.debug(f'{heading}: {orig_val}{misc_utils.pretty_print_json(json_val)}')

        new_method = z.json()
        _log.debug(f'{misc_utils.pretty_print_json(new_method)=}')

        snapshot_id = new_method['snapshotId']

        acl_updates = [{'role': 'OWNER', 'user': user} for user in terra_config['users']]
        _log_json('acl_updates', acl_updates)
        z = fapi.update_repository_method_acl(namespace=SEL_NAMESPACE, method=TERRA_METHOD_NAME, snapshot_id=snapshot_id,
                                              acl_updates=acl_updates)
        _log_json('ACL UPDATE result', z)
        z = fapi.get_repository_method_acl(namespace=SEL_NAMESPACE, method=TERRA_METHOD_NAME, snapshot_id=snapshot_id)
        _log_json('ACL AFTER UPDATE', z)

        z = fapi.get_config_template(namespace=SEL_NAMESPACE, method=TERRA_METHOD_NAME, version=snapshot_id)
        config_template = z.json()

        TERRA_CONFIG_NAME += f'_cfg_{snapshot_id}' 

        if 'TRAVIS_COMMIT_MESSAGE' in os.environ:
            TERRA_CONFIG_NAME += ('_' + re.sub(r'([^A-Za-z0-9])', '_',
                                               os.environ['TRAVIS_COMMIT_MESSAGE'])[:128])
        
        config_json = copy.copy(config_template)
        config_json['methodConfigVersion'] = snapshot_id
        config_json['namespace'] = SEL_NAMESPACE   # configuration namespace
        config_json['name'] = TERRA_CONFIG_NAME
        config_json.pop('rootEntityType', None)

        wdl_inputs = dict(misc_utils.json_loadf(root_workflow_def['test_data']))
        terra_inputs = { k: json.dumps(v, sort_keys=True) for k, v in wdl_inputs.items() }
        config_json['inputs'].update(terra_inputs)

        _log_json('AFTER UPDATING METHODCONFIGVERSION config_json is', config_json)

        z = fapi.create_workspace_config(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, body=config_json)
        _log_json('CREATED CONFIG WITH OUR INPUTS:', z)

        z = fapi.validate_config(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, cnamespace=SEL_NAMESPACE, config=TERRA_CONFIG_NAME)
        _log_json('VALIDATE_CONFIG:', z)
        validation_json = z.json()
        for field in ('extraInputs', 'invalidInputs', 'invalidOutputs', 'missingInputs'):
            misc_utils.chk(not validation_json.get(field, []),
                           f'Validation error in workflow {root_workflow_name}: {field} - {validation_json[field]}')

        z = fapi.get_repository_config_acl(namespace=SEL_NAMESPACE, config=TERRA_CONFIG_NAME, snapshot_id=1)
        _log_json('REPO CONFIG ACL:', z)

        z = fapi.get_workspace_acl(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE)
        _log_json('WORKSPACE ACL:', z)

        z = fapi.get_workspace_config(workspace=SEL_WORKSPACE, namespace=SEL_NAMESPACE,
                                      config=TERRA_CONFIG_NAME, cnamespace=SEL_NAMESPACE)

        _log_json('CONFIG_NOW_IS_2', z)

        z = fapi.create_submission(wnamespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE,
                                   cnamespace=SEL_NAMESPACE, config=TERRA_CONFIG_NAME)
        _log_json('SUBMISSION IS', z)

    # end: for root_workflow in terra_config['root_workflows']
# end: def do_deploy_to_terra(args)

def get_workflow_metadata_gz(namespace, workspace, submission_id, workflow_id, expand_subworkflows=False):
    """Request the metadata for a workflow in a submission.

    Args:
        namespace (str): project to which workspace belongs
        workspace (str): Workspace name
        submission_id (str): Submission's unique identifier
        workflow_id (str): Workflow's unique identifier.

    Swagger:
        https://api.firecloud.org/#!/Submissions/workflowMetadata
    """
    uri = "workspaces/{0}/{1}/submissions/{2}/workflows/{3}".format(namespace, workspace, submission_id, workflow_id)
    if expand_subworkflows:
        uri += '?expandSubWorkflows=true'
    try:
        headers = copy.deepcopy(fapi._fiss_agent_header())
        headers.update({'Accept-Encoding': 'gzip', 'User-Agent': 'gzip'})
    except Exception as e:
        _log.warning(f'get_workflow_metadata_gz: error getting default fiss agent headers - {e}')
        headers = None
    return fapi.__get(uri, headers=headers, timeout=240)
# end: def get_workflow_metadata_gz(namespace, workspace, submission_id, workflow_id)

def do_list_submissions(args):
    """Lists workflow submissions in Terra"""

    misc_utils.mkdir_p(args.tmp_dir)

    terra_config = misc_utils.load_config(args.config_file)['terra']
    SEL_NAMESPACE = terra_config['namespace']
    SEL_WORKSPACE = terra_config['workspace']

    #print('ENTITIES ARE', fapi.list_entity_types(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE).json())
    z = fapi.list_submissions(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE)
    #print('SUBMISSIONS ARE', z, z.json())

    def safe_fname(f):
        return os.path.join(os.path.dirname(f),
                            misc_utils.string_to_file_name(os.path.basename(f)))

    misc_utils.write_json_and_org(safe_fname(f'{args.tmp_dir}/submissions.json'), **{'result': list(z.json())})
    tot_time = 0
    for submission_idx, s in enumerate(sorted(list(z.json()), key=operator.itemgetter('submissionDate'), reverse=True)):
        _log.info(f'looking at submission from {s["submissionDate"]}: {s["submissionId"]=}')
        submission_date = s['submissionDate']
        if args.submission_date == 'today':
             args.submission_date = datetime.datetime.now().strftime('%Y-%m-%d')
        if args.submission_date and not submission_date.startswith(args.submission_date): 
            _log.info(f'skipping submission date {submission_date}')
            continue
        submission_id = s['submissionId']
        if args.submission_id and args.submission_id not in submission_id:
            _log.info(f'skipping submission id {submission_id}')
            continue

        _log.info('====================================================')
        _log.info(f'{s=}')
        _log.info(f'getting submission')
        submission_id = s['submissionId']
        method_configuration_name = s['methodConfigurationName']
        if args.method_config and method_configuration_name != args.method_config:
            _log.info(f'skipping submission since method config does not match {args.method_config=}')
            continue
        y = fapi.get_submission(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, submission_id=submission_id).json()
        _log.info('got submission')
        misc_utils.write_json_and_org(safe_fname(f'{args.tmp_dir}/{method_configuration_name}.{submission_date}.{submission_idx}.'
                                                 f'{submission_id}'
                                                 f'.subm.json'), **y)
        if 'workflowId' not in y['workflows'][0]:
            _log.warning(f'workflow ID missing from submission!')
            continue
        _log.info(f"getting workflow metadata for workflow id {y['workflows'][0]['workflowId']}")
        beg = time.time()

        workflow_ids = [y['workflows'][0]['workflowId']]
        while workflow_ids:
            workflow_id = workflow_ids.pop()
            _log.info(f'PROCESSING WORKFLOW: {workflow_id}')

            time.sleep(1)
            zz_result = get_workflow_metadata_gz(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, submission_id=submission_id,
                                                 workflow_id=workflow_id, expand_subworkflows=args.expand_subworkflows)
            # #print('ZZ_RESULT: ', type(zz_result), dir(zz_result), zz_result)
            # for f in dir(zz_result):
            #     _log.debug(f'  {f} = {getattr(zz_result, f)}')
            # #print('ZZ_RESULT.raw: ', type(zz_result.raw), dir(zz_result.raw), zz_result.raw)
            # for f in dir(zz_result.raw):
            #     _log.debug(f'  {f} = {getattr(zz_result.raw, f)}')
            # _log.debug(f'converting workflow metadata to json')
            try:
                zz = zz_result.json()
            except Exception as e:
                _log.error(f'Error converting to json: {e}')
                zz = {}
            tot_time += (time.time() - beg)
            _log.debug(f'saving workflow metadata')
            workflow_name = zz.get('workflowName', 'no_wf_name')
            misc_utils.write_json_and_org(safe_fname(f'{args.tmp_dir}/{method_configuration_name}.{submission_date}.{submission_idx}.'
                                                     f'{submission_id}.{workflow_id}'
                                                     f'.{workflow_name}.mdata.json'), **zz)
            if 'submittedFiles' in zz:
                misc_utils.dump_file(fname=safe_fname(f'{args.tmp_dir}/{method_configuration_name}.{submission_date}.{submission_idx}.'
                                                      f'{submission_id}.{workflow_id}.workflow.wdl'),
                                     value=zz['submittedFiles']['workflow'])

            jsons = [zz]
            while jsons:
                js = jsons.pop()
                #print('EXAMINING js: ', js)
                if isinstance(js, list):
                    jsons.extend(js)
                elif isinstance(js, dict):
                    if 'subWorkflowId' in js:
                        _log.debug(f'Found subworkflow id: {js["subWorkflowId"]}')
                        workflow_ids.append(js['subWorkflowId'])
                    jsons.extend(list(js.values()))
                else:
                    if 'subWorkflowId' in str(js):
                        raise RuntimeError(f'Missed subworkflowId in {js}')


        #succ = [v["succeeded"] for v in zz['outputs']["run_sims_cosi2.replicaInfos"]]
        #print(f'Succeeded: {sum(succ)} of {len(succ)}')

        # zzz = fapi.get_workflow_metadata(namespace=SEL_NAMESPACE, workspace=SEL_WORKSPACE, submission_id=s['submissionId'],
        #                                 workflow_id='ad1e8271-fe66-4e05-9005-af570e9e5884').json()
        # _write_json('tmp/jz.json', **zzz)

    _log.info(f'{tot_time=}')
# end: def do_list_submissions(args)

# * Parsing command line args

# argparse subcommands setup from
# https://gist.github.com/mivade/384c2c41c3a29c637cb6c603d4197f9f

def parse_args():

    cli = argparse.ArgumentParser()

    cli.add_argument('--config-file', default='config/cms2_work_config.yml')
    cli.add_argument('--tmp-dir', default=os.path.realpath('tmp'))

    argument, subcommand, parse = misc_utils.subparsers_helper(cli)

    @subcommand()
    def deploy_to_terra(args):
        try:
            customize_wdls_for_git_commit()
            do_deploy_to_terra(args)
        except Exception as e:
            _log.error(f'deploy_to_terra: ERROR {e}')
            raise

    @subcommand()
    def update_wdl_dockers(args):
        try:
            do_update_wdl_dockers()
        except Exception as e:
            _log.error(f'update_wdl_dockers: ERROR {e}')
            raise

    # @subcommand([argument("-d", help="Debug mode", action="store_true")])
    # def test(args):
    #     print(args)

    @subcommand([argument('-s', '--submission-date', help='submission date'),
                 argument('-i', '--submission-id', help='submission date'),
                 argument('--expand-subworkflows', action='store_true'),
                 argument('--method-config', help='only look at submissions where method config matches this')])
    def list_submissions(args):
        do_list_submissions(args)

    

    # @subcommand([argument("name", help="Name")])
    # def name(args):
    #     print(args.name)
    parse()
# end: def parse_args()

if __name__ == "__main__":
    parse_args()
