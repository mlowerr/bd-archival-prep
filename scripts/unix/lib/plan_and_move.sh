#!/bin/bash
~/git/bd-archival-prep/scripts/unix/file-size-recommendations.sh
python3 ~/git/bd-archival-prep/scripts/unix/apply-disk-plan.py --recommendations .archival-prep/blu-ray-file-recommendations.txt --destination .

