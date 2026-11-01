#!/bin/bash
# Runs inside the locked SDK image: what does this SDK's lexlean offer, and does the kernel model build?
set -uo pipefail
cd feasibility/kernels
echo "### versions"
lexlean --version
lean --version
rustc --version
command -v lake leanchecker cargo python3 node
echo "### lexlean help"
lexlean --help 2>&1 | head -40
echo "### production help"
lexlean production --help 2>&1 | head -20
echo "### targets"
lexlean production targets > ../out/targets.json
echo "targets exit $?"
head -c 1500 ../out/targets.json
echo
echo "### fmt, lock, check"
lexlean fmt
echo "fmt exit $?"
lexlean lock
echo "lock exit $?"
lexlean check
echo "check exit $?"
