import copy,json,os,subprocess,tempfile
from pathlib import Path
from jsonschema import Draft202012Validator
spec=json.loads(Path('site/openapi.json').read_text())
assert spec['openapi']=='3.1.0'
assert list(spec['paths'])==['/data.json']
for schema in spec['components']['schemas'].values():
    Draft202012Validator.check_schema(schema)
v=Draft202012Validator({'$ref':'#/components/schemas/Snapshot','components':spec['components']})
sample=json.loads(Path('tests/snapshot.example.json').read_text())
v.validate(sample)
missing=copy.deepcopy(sample)
for key in ['runs','chain','token','wallets','proxy','monitor','nightly']:
    missing[key]=None
for source in missing['sources'].values():
    source.update(status='error',error='unavailable',last_success=None)
missing['hosts']={'oracle':[],'agent':[],'agent_errors_6h':None,'agent_published_24h':None}
v.validate(missing)
for name,mutate in [
    ('noninteger wallet balance',lambda x:x['wallets']['accounts'][0].update(balance_lovelace=12.5)),
    ('unknown source state',lambda x:x['sources']['wallets'].update(status='healthy')),
    ('missing producer metadata',lambda x:x.pop('generated_at')),
    ('invented completed history',lambda x:x['wallets'].update(history_status='complete')),
]:
    broken=copy.deepcopy(sample)
    mutate(broken)
    if not list(v.iter_errors(broken)):
        raise AssertionError('schema accepted '+name)
print('snapshot schema accepts observed and unavailable states; malformed claims refused')

# Bind the contract to real collector output, not only a recorded example.
with tempfile.TemporaryDirectory(prefix='snapshot-contract-') as directory:
    root=Path(directory)
    binaries=root/'bin'
    binaries.mkdir()
    for name in ['curl','moog']:
        command=binaries/name
        command.write_text('#!/bin/sh\nexit 1\n')
        command.chmod(0o755)
    environment=os.environ.copy()
    environment.update(PATH=str(binaries)+os.pathsep+environment['PATH'],
        DASHBOARD_CACHE=str(root/'cache'),DASHBOARD_OUT=str(root/'out'),
        ANTITHESIS_API_KEY_FILE=str(root/'absent-key'),GH_READ_TOKEN_FILE=str(root/'absent-read'),
        MOOG_READ_ENV_FILE=str(root/'absent-moog'),MOOG_DIR=str(binaries),
        STATUS_ISSUE_ORACLE='',STATUS_ISSUE_AGENT='',STATUS_ISSUE_MONITOR='')
    subprocess.run(['bash','collect/collect.sh'],env=environment,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    v.validate(json.loads((root/'out/data.json').read_text()))
print('actual collector output conforms to the snapshot contract')
