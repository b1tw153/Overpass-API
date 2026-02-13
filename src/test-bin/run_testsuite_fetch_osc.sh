#!/usr/bin/env bash

# Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
#
# This file is part of Overpass_API.
#
# Overpass_API is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# Overpass_API is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with Overpass_API. If not, see <https://www.gnu.org/licenses/>.

if [[ -z $1  ]]; then
{
  echo "Usage: $0 test_size no_times"
  echo
  echo "The test_size and no_times parameters are ignored in this test suite."
  exit 0
};
fi

# The size of the test pattern. Asymptotically, the test pattern consists of
# size^2 elements. The size must be divisible by ten. For a full featured test,
# set the value to 2000.
# DATA_SIZE="$1"
BASEDIR="$(cd "$(dirname "$0")/.." || exit; pwd)"
# NOTIMES="$2"

# Test usage output with no arguments
mkdir -p run/fetch_osc_1
rm -fR run/fetch_osc_1/*
"$BASEDIR/bin/fetch_osc.sh" >"run/fetch_osc_1/stdout.log" 2>"run/fetch_osc_1/stderr.log"
FETCH_OSC_EXIT=$?
RES=
if [[ $FETCH_OSC_EXIT -eq 0 ]]; then
{
  RES="expected non-zero exit code, got 0"
}; fi
if ! grep -q "Usage:" "run/fetch_osc_1/stdout.log"; then
{
  RES="${RES:+$RES; }expected 'Usage:' in stdout"
}; fi
if [[ -n $RES ]]; then
{
  echo "$(date +%T) Test fetch_osc 1 FAILED: $RES"
}; else
{
  echo "$(date +%T) Test fetch_osc 1 succeeded."
  rm -R run/fetch_osc_1
}; fi

# Test operation with a specified starting replicate_id
# HINT: 02_basic_fetch.sh

# Test error message with auto when the database has no replicate_id
# HINT: 04_auto_with_dispatcher_and_replicate.sh

# Test operation with auto when the database has a replicate_id
# HINT: 03_auto_missing_replicate_id.sh

# Test continuous retries when waiting for new updates
# HINT: 37_retry_when_no_updates.sh

# Test validation of $1 (replicate_id) with non-numeric input [BUG]
# HINT: 07_non_numeric_replicate_id.sh

# Test validation of $1 (replicate_id) with negative input [BUG]
# HINT: 13_negative_replicate_id.sh

# Test validation of $2 (source_url) with empty input [BUG]
# HINT: 05_missing_source_dir.sh

# Test validation of $3 (local_dir) with empty input [BUG]
# HINT: 06_missing_local_dir.sh

# Test validation of $4 (sleep) with non-numeric input [BUG]
# HINT: New test case similar to 07_non_numeric_replicate_id.sh but for the sleep parameter

# Test malformed root state.txt file with missing sequenceNumber [BUG]
# HINT: 09_malformed_state_txt.sh

# Test malformed root state.txt file with non-numeric sequenceNumber [BUG]
# HINT: 14_sequence_number_invalid.sh

# Test usage of $3 (local_dir) with spaces in path [BUG]
# HINT: 17_local_dir_with_spaces.sh

# Test persistent HTTP errors while fetching root state.txt file [BUG]
# HINT: 19_http_404_error.sh

# Test HTTP 404 response when fetching .osc.gz file [BUG]
# HINT: 23_html_as_data.sh

# Test empty response when fetching .osc.gz file [BUG]
# HINT: 24_empty_downloads.sh

# Test truncated .osc.gz file [BUG]
# HINT: 30_truncated_osc_gz_footer.sh

# Test stalled .osc.gz download [BUG]
# HINT: 34_stalled_connection_timeout.sh

# Test malformed .state.txt file with missing timestamp [BUG]
# HINT: 27_truncated_state_no_timestamp.sh

# Test operation with missing download tools (i.e., curl and wget) [BUG]
# HINT: 31_missing_download_tools.sh

# Test recovery after downloading a partial .osc.gz file [BUG]
# HINT: 36_preexisting_partial_osc.sh
