#!/usr/bin/env python3

"""Command-line interface to the Neutral Regions Explorer webserver.
"""

# import webdriver
# from selenium import webdriver
# import chromedriver_binary
  
# # create webdriver object
# driver = webdriver.Chrome()
  
# # get geeksforgeeks.org
# driver.get("http://nre.cb.bscb.cornell.edu/nre/run.html")

import platform

if not tuple(map(int, platform.python_version_tuple())) >= (3,8):
    raise RuntimeError('Python >=3.8 required')

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
import urllib
import urllib.request

from selenium import webdriver
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import chromedriver_binary

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

def chk(cond, msg='condition failed'):
    if not cond:
        raise RuntimeError(f'Error: {msg}') 

def reverse_dict(d):
    result = {v: k for k, v in d.items()}
    chk(len(result) == len(d), f'reverse_dict: non-unique values in dict {d}')
    return result

def parse_args():
    parser = argparse.ArgumentParser()

    parser.add_argument('--nre-url', default='http://nre.cb.bscb.cornell.edu/nre/run.html')
    parser.add_argument('--nre-timeout-seconds', type=float, default=7200)
    parser.add_argument('--nre-poll-frequency-seconds', type=float, default=30)

    parser.add_argument('--nre-params', required=True, help='inputs as json')

    parser.add_argument('--neutral-regions-tsv', required=True, help='output file for nre results')
    parser.add_argument('--neutral-regions-bed', required=True, help='output bed file for nre results')
    parser.add_argument('--nre-submitted-form-html', help='the form submitted to the NRE is saved here')
    parser.add_argument('--nre-submitted-values-json', help='the submitted values')
    parser.add_argument('--nre-results-html', help='the results web page')
    parser.add_argument('--nre-results-url', help='the results URL')

    return parser.parse_args()

def submit_neutral_region_explorer_job(args):

    inps = _json_loadf(args.nre_params)

    null_inps = [inp for inp, val in inps.items() if val is None]
    for null_inp in null_inps:
        del inps[null_inp]

    options = webdriver.ChromeOptions()
    options.add_argument("--headless")

    driver = webdriver.Chrome(options=options)

    driver.implicitly_wait(30)
    driver.set_page_load_timeout(30)

    #driver.get('http://www.google.com')
    #print(driver.title)

    driver.get(args.nre_url)
    driver.maximize_window()

    param_name_to_checkbox_name = {
        'known_genes': 'knownGene',
        'gene_bounds': 'rnaCluster',
        'spliced_ESTs': 'all_est',
        'segmental_duplications': 'genomicSuperDups',
        'CNVs': 'dgv',
        'self_chain': 'selfChain',
        'reduced_repeat_masker': 'rmskRTdivLT20',
        'simple_repeats': 'simpleRepeat',
        'repeat_masker': 'rmskRM327',
        'phast_conserved_plac_mammal': 'phastConsElements46wayPlacMammal',
    }
    
    for param_name, checkbox_name in param_name_to_checkbox_name.items():
        checkbox = driver.find_element_by_name(checkbox_name)
        if param_name in inps:
            if checkbox.is_selected() != inps[param_name]:
                _log.info(f'toggling: {param_name=} {checkbox_name=}')
                checkbox.click()
                time.sleep(2)
                chk(checkbox.is_selected() == inps[param_name], f'failed to set checkbox state: {param_name=} {checkbox_name=}')

        _log.info(f'{param_name=} {checkbox_name=} {checkbox.is_selected()=}')
    
    def find_submit_button():
        for e in driver.find_elements_by_tag_name('input'):
            print(e)
            #print(dir(e))
            if e.get_attribute('type') == 'submit':
                return e

    radio_buttons_groups = {
        'human_diversity': ('popu', {'CEU': 'ceu_filt', 'YRI': 'yri_filt', 'CHBJPT': 'chbjpt_filt'}),
        'distance_unit': ('cMbp', {'cM': 'cM', 'bp': 'bp'})
    }
    for param_name, (radio_button_group_name, inp2value) in radio_button_groups.items():
        if param_name in inps:
            chk(inps[param_name] in inp2value, f'invalid {param_name} value: {inps[param_name]}')
            found_radio_button = False
            for e in driver.find_elements_by_name(radio_button_group_name):
                found_radio_button = False
                for inp, val in inp2value.items():
                    if inps[param_name] == inp   and  e.get_attribute('value') == val:
                        found_radio_button = True
                        e.click()
                        time.sleep(2)
                        break
                if found_radio_button:
                    break
            # end: for e in driver.find_elements_by_name(radiobox_name)
            chk(found_radio_button, f'Did not find radio button for {param_name}')
        # end: if param_name in inps
    # end: for param_name, (radio_button_group_name, inp2value) in radio_boxes.items()

    param_name2input_name = {
        'chromosomes': 'chromosomes',
        'minimum_region_size': 'min_reg_sz',
        'minimum_distance_to_nearest_gene': 'd2g_min',
        'maximum_distance_to_nearest_gene': 'd2g_max',
        'recomb_rate_min': 'r_min',
        'recomb_rate_max': 'r_max'
    }

    for param_name, input_name in param_name2input_name.items():
        if param_name in inps:
            driver.find_element_by_name(input_name).clear()
            driver.find_element_by_name(input_name).send_keys(str(inps[param_name]))

    param_name_to_input_id = {
        'regions_to_exclude_bed': 'hardf',
        'gene_regions_bed': 'usrGenes'
    }
    
    for param_name, input_id in param_name_to_input_id.items():
        if param_name in inps:
            for f in inps[param_name]:
                driver.find_element_by_id(input_id).send_keys(str(inps[param_name]))

    current_url = driver.current_url

    if args.nre_submitted_form_html:
        dump_file(fname=args.nre_submitted_form_html, value=driver.page_source)

    if args.nre_submitted_values_json:
        submitted_values = {}
        for param_name, checkbox_name in param_name_to_checkbox_name.items():
            submitted_values[param_name] = driver.find_element_by_name(checkbox_name).is_selected()
        for param_name, input_name in param_name2input_name.items():
            submitted_values[param_name] = driver.find_element_by_name(input_name).get_attribute('value')
        for param_name, input_id in param_name_to_input_id.items():
            submitted_values[param_name] = driver.find_element_by_id(input_id).get_attribute('value')

        for param_name, (radio_button_group_name, inp2value) in radio_button_groups.items():
            selected_radio_button_value = [e.get_attribute('value') for e in driver.find_elements_by_name(radio_button_group_name) \
                                           if e.is_selected()][0]
            submitted_values[param_name] = reverse_dict(inp2value)[selected_radio_button_value]
        # end: for param_name, (radio_button_group_name, inp2value) in radio_boxes.items()

        _write_json(fname=args.nre_submitted_values_json, json_val=submitted_values)

    #sys.exit(1)

    find_submit_button().click()
    time.sleep(2)

    #driver.refresh()
    # some work on current page, code omitted

    # save current page url

    _log.debug(f'waiting for {current_url=} to change')

    # initiate page transition, e.g.:
    #input_element.send_keys(post_number)
    #input_element.submit()

    # wait for URL to change with 15 seconds timeout
    WebDriverWait(driver, timeout=args.nre_timeout_seconds, poll_frequency=args.nre_poll_frequency_seconds).\
        until(EC.url_changes(current_url))

    # print new URL
    new_url = driver.current_url
    _log.info(f'{new_url=}')

    return driver
# end: def submit_neutral_region_explorer_job(nre_url)

def wait_for_nre_results(driver, args):
    beg_time = time.time()
    while True:
        if (time.time() - beg_time) > args.nre_timeout_seconds:
            raise RuntimeError('Timed out waiting for results')
        time.sleep(args.nre_poll_frequency_seconds)
        driver.refresh()
        if 'NRE: Results' in driver.title:

            if args.nre_results_url:
                dump_file(fname=args.nre_results_url, value=driver.current_url)
            if args.nre_results_html:
                dump_file(fname=args.nre_results_html, value=driver.page_source)

            analysis_id = driver.current_url.split('=')[1]
            results_url = f'http://nre.cb.bscb.cornell.edu/nre/user/{analysis_id}/results_Hard.tsv'
            _log.info(f'Fetching results: {results_url=} {args.neutral_regions_tsv=}')
            urllib.request.urlretrieve(results_url, args.neutral_regions_tsv)

            with open(args.neutral_regions_tsv) as nre_results_tsv, open(args.neutral_regions_bed, 'w') as nre_results_bed:
                for line_num, line in enumerate(nre_results_tsv):
                    if line_num == 0:
                        chk(line.startswith('chrom'), 'unexpected start line')
                        continue
                    fields = line.strip().split()
                    chk(fields[0].startswith('chr'), 'chrom line does not start with chr')
                    nre_results_bed.write('\t'.join([fields[0][3:], fields[1], fields[2]]) + '\n')
                    
            return
        else:
            _log.info(f'Waiting for NRE results: {driver.title=} {args=}')
  
# get element 
#element = driver.find_element_by_id("gsc-i-id2")
  
# send keys 
#element.send_keys("Arrays")
  
# submit contents
#element.submit()

def call_nre(args):
    driver = submit_neutral_region_explorer_job(args)
    wait_for_nre_results(driver, args)

if __name__ == '__main__':
    call_nre(parse_args())
