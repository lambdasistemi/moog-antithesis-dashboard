"""Validate a dashboard snapshot against the contract shipped in a collector image.

usage: validate-snapshot.py OPENAPI.json DATA.json
Exit 0 when DATA conforms to #/components/schemas/Snapshot; 1 with the first
violation's path (never the value) otherwise.
"""
import json
import sys

from jsonschema import Draft202012Validator

spec = json.load(open(sys.argv[1]))
validator = Draft202012Validator({"$ref": "#/components/schemas/Snapshot", "components": spec["components"]})
try:
    data = json.load(open(sys.argv[2]))
except ValueError:
    print("snapshot is not JSON", file=sys.stderr)
    sys.exit(1)
errors = sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path))
if errors:
    path = "/".join(str(p) for p in errors[0].absolute_path) or "(root)"
    print("at " + path + ": " + errors[0].validator, file=sys.stderr)
    sys.exit(1)
