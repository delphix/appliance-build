#!/usr/bin/python
# -*- coding: utf-8 -*-

#
# Copyright (c) 2017, 2021 by Delphix. All rights reserved.
#

'''
For a version V, a customer can upgrade to V from any version in [min upgrade version of V, V), inclusive/exclusive.
If a customer's hotfix has a corresponding product bug which was fixed within [min upgrade version of V, V), this means
that the customer is safe to upgrade to V.  In other words, version V has the product "fix" for the customer's hotfix.

The goal of this script is to find all fixed hotfixes for a given version.
This script will only support versions > 5.3.5.0.

Exceptions: Currently DB2 hotfixes will not be fixed by the engine upgrade. They will be fixed by toolkit upgrades.

This will fail the build if a Hotfix is moved to one of ["Ready To Deploy", "Fix Failed", "Fix Verified", "Integrated"]
without a linked DLPX or CP.
'''

import argparse
import os
import re
import sys
from distutils.version import LooseVersion
from jira import JIRA, JIRAError


jira=None


QUERY_VERSION_FIXED = 'project in (DLPX, CP) AND "Version Fixed" = %s'

# Using the date in the query since the rule of linking hotfixes to releases went into effect on 2016-12-09.
# Need to include the Jocacean version exclusion since there are 4 bugs whose Version Fixed is Jocacean and 5.2.0.0
# is not in the list of releases in Jira.

HOTFIXES_ON_CUSTOMER_SYSTEMS = \
  '(project = Hotfixes AND created > 2016-12-09 AND "Version Fixed" != Jocacean )  or ' \
  '(project = Hotfixes AND created > 2016-12-09 AND "Version Fixed" is EMPTY AND ' \
  'issueFunction in hasLinkType("Relates"))'
JIRA_MAX_RESULTS = 1000


def die(msg):
  print('\nUnable to generate metadata: ' + msg)
  sys.exit(1)


# This method make our lives easier because JIRA keeps the information
# about which issue the user created the link from (outward).  There is no easy
# way to just get the linked issue, so we try both inward and outward.

def resolve_link(link):
  try:
    return link.inwardIssue
  except AttributeError:
    return link.outwardIssue


def check_link_is_for_backport(link):
  link_string = 'backported by'
  try:
    link.inwardIssue
    return link.type.inward == link_string
  except:
    return link.type.outward == link_string


def check_link_is_for_dup(link):
  link_string = ['is duplicated by', 'duplicates']
  try:
    link.inwardIssue
    return link.type.inward in link_string
  except:
    return link.type.outward in link_string


def append_to_file(str, file):
  with open(file, 'a') as f:
    f.write(str)


def get_linked_dlpx_to_hotfix(hf):
  linked_dlpx = list()
  for link in map(resolve_link, hf.fields.issuelinks):
    issue = jira.issue(link.key)
    if issue.fields.project.key in ['DLPX', 'CP']:
      linked_dlpx.append(issue)
  return linked_dlpx


def get_linked_duplicate_to_dlpx(dlpx):
  for link in dlpx.fields.issuelinks:
    if check_link_is_for_dup(link) == True:
      issue = jira.issue(resolve_link(link).key)
      if issue.fields.project.key in ['DLPX', 'CP']:
        return issue
  return None


def get_backports(dlpx):
  backports = list()
  for link in dlpx.fields.issuelinks:
    if check_link_is_for_backport(link):
      issue = jira.issue(resolve_link(link).key)
      backports.append(issue)
  return backports


def remove_bugs_that_caused_hotfix(linked_dlpx, hf):
  sanitised_list = list()
  for dlpx in linked_dlpx:
    if hf.fields.customfield_10500 is not None \
        and dlpx.fields.customfield_10500 is not None:

      # Remove Bugs that are probably the cause of the hotfix.

      if LooseVersion(hf.fields.customfield_10500.name) \
          >= LooseVersion(dlpx.fields.customfield_10500.name):
        continue
    sanitised_list.append(dlpx)
  return sanitised_list


def fixup_bugs_list(linked_dlpx):

  # Fix duplicate bugs link
  # Remove invalid bugs

  sanitised_list = list()
  for dlpx in linked_dlpx:
    if dlpx.fields.resolution is not None:
      if dlpx.fields.resolution.name == 'Duplicate':
        dup = get_linked_duplicate_to_dlpx(dlpx)
        assert dup is not None, \
          '{} does not have any duplicate links'.format(dlpx.key)
        sanitised_list.append(dup)
        continue
      elif dlpx.fields.resolution.name == 'Not a bug':
        continue
    sanitised_list.append(dlpx)
  return sanitised_list


def run_sanity_tests():
  try:

    # We have constructed the following on JIRA for testing:
    #
    # Backport-49266 -- DLPX-49264 -- HF-353
    #                   /
    #        Backport-72007
    #
    #                DLPX-46713
    #               /          \
    # Backport-49265            HF-351 - ESCL-103 - DLPX-72008
    #               \          /
    #                DLPX-48962 -- HF-352
    #
    #

    # Test that we correctly get the linked DLPX from a hotfix

    results = get_linked_dlpx_to_hotfix(jira.issue('HF-351'))
    result_keys = [r.key for r in results]
    assert set(result_keys) == set(['DLPX-46713', 'DLPX-48962']), 'Error getting linked DLPX for HF-351'

    results = get_backports(jira.issue('DLPX-49264'))
    result_keys = [r.key for r in results]
    assert set(result_keys) == set(['DLPX-49266', 'DLPX-72007']), \
      'Error getting linked backport for DLPX-49264'
  except Exception as e:

    print ('Unexpected error:', e)
    return False
  return True


def main():
  parser = argparse.ArgumentParser()
  parser.add_argument('-t', '--test',
                      help='Run only the sanity tests (ignore all other options)'
                      , action='store_true')
  parser.add_argument('-v', '--version',
                      help='The version you want to add in the form of x.x.x.x'
                      )
  parser.add_argument('-o', '--outfile',
                      help='The file to save the generated hotfix metadata for the given version'
                      , default='/tmp/hf_new')

  args = parser.parse_args()
  test = args.test
  version = args.version
  outfile = args.outfile

  # Create an empty file if we do not have a version to avoid having to check for file existence in
  # scripts that consume the file.
  if version == "trunk" or not version:
    with open(outfile, 'a') as f:
      f.write("")
    exit()

  # Parse command line args

  if args.test:
    if not run_sanity_tests():
      die('Sanity tests failed')
    print('Sanity tests passed')
    sys.exit(0)
  else:
    if version is None or outfile is None:
      parser.error('if -t is not given, -v and -o are required')


  # We allow some flexibility in version strings. So long as the version
  # string starts with what looks like a version we accept it
  # so that we can accept version strings that represent an
  # unreleased appliance version (e.g.
  # 6.1.0.0-snapshot.20210706184036139...)
  match=re.search("^[0-9]+\.[0-9]+\.[0-9]+.[0-9]+", version)

  if match:
    version = match.group()
  else:
    die("version must start with 4 numerals separated by '.'")

  # Check if appropriate environment variables are set so that we can query Jira

  JIRA_URL = os.getenv('JIRA_URL', None)
  JIRA_USER = os.getenv('JIRA_USER', None)
  JIRA_PASSWORD = os.getenv('JIRA_PASSWORD', None)

  # Gradle will pass in the string "null" if the values are not set
  errors = []
  if not JIRA_URL or JIRA_URL == 'null':
    errors.append("Environment variable JIRA_URL not set.")
  if not JIRA_USER or JIRA_USER == 'null':
    errors.append("Environment variable JIRA_USER not set.")
  if not JIRA_PASSWORD or JIRA_PASSWORD == 'null':
    errors.append("Environment variable JIRA_PASSWORD not set.")

  if errors:
    die("\n".join(errors))


  global jira
  jira = JIRA(server=JIRA_URL, basic_auth=(JIRA_USER, JIRA_PASSWORD))

  fixed_hotfixes = list()
  hotfixes = jira.search_issues(HOTFIXES_ON_CUSTOMER_SYSTEMS,
                                maxResults=JIRA_MAX_RESULTS)
  if len(hotfixes) > 999:
    die('Need to implement paging for the list of hotfixes')

  for hf in hotfixes:
    if hf.fields.customfield_10500 is not None:

      # Make sure that the version is set to X.X.X.X except for DB2,PostgreSQL which has their own release number.
      # Special handling for Jocacean version name since its hard to replace in JIRA for historical reasons.

      assert len(hf.fields.customfield_10500.name.replace('Jocacean'
                                                          , '5.2.0.0').split('.')) == 4 or set([comp.name
                                                                                                for comp in
                                                                                                hf.fields.components]).issubset(set(['DB2',
                                                                                                                                     'PostgreSQL'])), \
        '{version} is not of the format X.X.X.X for {hf}'.format(version=hf.fields.customfield_10500.name,
                                                                 hf=hf.key)

      # Only care about hotfixes after 5.3.5.0 since customers can only upgrade from 5.3.6.0 to 6.0.X.X and above

      if LooseVersion(hf.fields.customfield_10500.name) \
          <= LooseVersion('5.3.5.0'):
        continue
    linked_dlpx = \
      remove_bugs_that_caused_hotfix(get_linked_dlpx_to_hotfix(hf),
                                     hf)
    linked_dlpx = fixup_bugs_list(linked_dlpx)
    assert len(linked_dlpx) > 0 or set([comp.name for comp in
                                        hf.fields.components]).issubset(set(['DB2', 'PostgreSQL'
                                                                             ])) or hf.fields.status.name not in ['Ready To Deploy',
                                                                                                                  'Fix Failed', 'Fix Verified', 'Integrated'], \
      '{} does not have any DLPX links'.format(hf.key)

    # Tracking product bug has not been filed. Skip.

    if len(linked_dlpx) == 0:
      continue

    # Check that all the linked DLPXs are fixed in a release < args.version
    # before adding it to the list of fixed hotfixes.

    for dlpx in linked_dlpx:
      backports = list()
      if dlpx.fields.customfield_10500 is not None:
        assert len(dlpx.fields.customfield_10500.name.replace('Jocacean'
                                                              , '5.2.0.0').split('.')) == 4, \
          'Version Fixed is not of the format X.X.X.X for {}'.format(dlpx.key)

        dlpx_version = LooseVersion(dlpx.fields.customfield_10500.name)
        if dlpx_version.__str__() == "Jocacean":
          dlpx_version = LooseVersion("5.2.0.0")
        if  dlpx_version <= LooseVersion(args.version):
          continue
        else:

          # Get the list of backports to see if any of the backports fixed this issue.

          backports.extend(get_backports(dlpx))
      else:
        backports.extend(get_backports(dlpx))
      for backport in backports:
        if backport.fields.customfield_10500 is not None:
          assert len(backport.fields.customfield_10500.name.replace('Jocacean'
                                                                    , '5.2.0.0').split('.')) == 4
          if LooseVersion(backport.fields.customfield_10500.name) \
              <= LooseVersion(args.version):
            break
      else:
        break
    else:

      # If the loop completes normally, then the linked bugs were all fixed in an earlier release

      fixed_hotfixes.append(hf.key)

  append_to_file('\n'.join(fixed_hotfixes) + '\n', outfile)


if __name__ == '__main__':
  main()
