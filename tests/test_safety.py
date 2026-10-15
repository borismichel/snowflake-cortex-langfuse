"""Offline regression tests execute the actual shipped SQL SELECT and Python bodies.
SQLite validates resolver decisions, not Snowflake compilation or SQL scripting.
HTTP and Snowpark are mocked; no account access or live telemetry sends.
"""
import ast
import json
import re
import sqlite3
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / 'sql'

def body(name, index=0):
    bodies = [b for b in (SQL / name).read_text().split('$$')[1::2] if b.lstrip().startswith('import ')]
    ns = {}
    with unittest.mock.patch.dict(sys.modules, {'_snowflake': types.ModuleType('_snowflake'), 'requests': types.ModuleType('requests')}):
        exec(compile(bodies[index], name, 'exec'), ns)
    return ns

class ArrayAgg:
    def __init__(self): self.items = []
    def step(self, x): self.items.append(x)
    def finalize(self): return json.dumps(self.items)

class Routing(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.row_factory = sqlite3.Row
        self.db.create_aggregate('ARRAY_AGG', 1, ArrayAgg)
        self.db.executescript('''
          CREATE TABLE TRACES(trace_id, route_status, agent_database, agent_schema, agent_name, agent_object_id);
          CREATE TABLE ROUTES(route_id, enabled, match_level, agent_database, agent_schema, agent_name, agent_object_id, action, destination_id);
          CREATE TABLE DESTINATIONS(destination_id,langfuse_host,project_id,publication_mode,required_billing,enabled,paused_reason);
          INSERT INTO TRACES VALUES ('trace',NULL,'DB','PUBLIC','A','id-a');
          INSERT INTO DESTINATIONS VALUES ('shared','https://host','p1','TRACE_FIRST','[]',1,NULL);
          INSERT INTO DESTINATIONS VALUES ('team','https://host','p2','TRACE_FIRST','[]',1,NULL);
        ''')
        text = (SQL / '04_staging_routing.sql').read_text()
        query = text.split('CREATE OR REPLACE VIEW LANGFUSE_EXPORTER.CORE.ROUTE_PREVIEW_V AS\n')[1].split(';',1)[0]
        self.query = query.replace('LANGFUSE_EXPORTER.CORE.', '')
    def route(self, rid, level='AGENT', dest='team', action='ROUTE', name='A'):
        self.db.execute('INSERT INTO ROUTES VALUES (?,1,?,?,?,?,NULL,?,?)', (rid,level,'DB','PUBLIC',name,action,dest))
    def result(self): return self.db.execute(self.query).fetchone()
    def test_missing_override_never_falls_back(self):
        self.route('default','ACCOUNT','shared');self.route('agent',dest='missing')
        self.assertEqual(self.result()['resolution_status'],'CONFIG_ERROR')
    def test_precedence(self):
        for level in ['ACCOUNT','DATABASE','SCHEMA']: self.route(level,level,'shared')
        self.route('agent');self.assertEqual(self.result()['destination_id'],'team')
    def test_conflicting_routes_hold(self):
        self.route('a');self.route('b',dest='shared')
        self.assertEqual(self.result()['resolution_status'],'CONFIG_ERROR')
    def test_duplicate_same_destination_holds(self):
        self.route('a');self.route('b')
        self.assertEqual(self.result()['resolution_status'],'CONFIG_ERROR')
    def test_exclusion_wins_same_level(self):
        self.route('a');self.route('b',action='EXCLUDE',dest=None)
        self.assertEqual(self.result()['resolution_status'],'EXCLUDED')
    def test_specific_route_overrides_broad_exclusion(self):
        self.route('x','ACCOUNT',action='EXCLUDE');self.route('a')
        self.assertEqual(self.result()['resolution_status'],'ROUTED')
    def test_disabled_paused_and_unconfigured_destination(self):
        self.route('a');self.route('default','ACCOUNT','shared')
        for assignment in ['enabled=0',"paused_reason='hold'",'project_id=NULL',"publication_mode='TYPO'"]:
            with self.subTest(assignment=assignment):
                self.db.execute("UPDATE DESTINATIONS SET enabled=1, paused_reason=NULL, project_id='p2', publication_mode='TRACE_FIRST'")
                self.db.execute('UPDATE DESTINATIONS SET '+assignment+" WHERE destination_id='team'")
                self.assertEqual(self.result()['resolution_status'],'CONFIG_ERROR')
    def test_exact_case(self):
        self.route('a',name='a');self.assertIsNone(self.result())
    def test_agent_object_id(self):
        self.route('a');self.db.execute("UPDATE ROUTES SET agent_object_id='different'")
        self.assertIsNone(self.result())
    def test_existing_decisions_frozen(self):
        self.route('a')
        for status in ['ROUTED','EXCLUDED']:
            self.db.execute('UPDATE TRACES SET route_status=?',(status,));self.assertIsNone(self.result())
    def test_config_error_can_recover(self):
        self.route('a');self.db.execute("UPDATE TRACES SET route_status='CONFIG_ERROR'")
        self.assertEqual(self.result()['resolution_status'],'ROUTED')
    def test_many_agents_share(self):
        self.route('a',dest='shared');self.route('b',dest='shared',name='B')
        self.db.execute("INSERT INTO TRACES VALUES ('trace-b',NULL,'DB','PUBLIC','B','id-b')")
        self.assertEqual([r['destination_id'] for r in self.db.execute(self.query)],['shared','shared'])

class Delivery(unittest.TestCase):
    def test_boundary_blocks_changed_host_project_alias_or_duplicate(self):
        ns=body('05b_sender.sql');ns['requests'].post=Mock(side_effect=AssertionError('must not send'))
        for rows in [[('d','https://wrong','p')],[('d','https://host','wrong')], [('other','https://host','p')], [], [('d','https://host','p')]*2]:
            with self.subTest(rows=rows):
                ns['q']=Mock(return_value=rows)
                result=ns['send_one'](None,'d','https://host','p',('key','secret'),5,'delivery')
                self.assertEqual(result['outcome'],'HELD_IDENTITY_MISMATCH')
                self.assertEqual(ns['q'].call_count,1)
        ns['requests'].post.assert_not_called()
    def test_claim_has_identity_predicate_and_sends_original_payload(self):
        ns=body('05b_sender.sql');calls=[]
        def q(session,sql,params=None):
            calls.append((sql,params))
            if 'SELECT destination_id, host' in sql:return [('d','https://host/','p')]
            if "SET status = 'IN_FLIGHT'" in sql:
                self.assertIn("destination_id = ? AND RTRIM(host, '/') = ? AND project_id = ?",sql)
                self.assertEqual(params[-3:],['d','https://host','p']);return [(1,)]
            if 'SELECT item_type' in sql:return [('TRACE_BATCH','{"original":true}',1,'trace')]
            return []
        ns['q']=q;ns['requests'].post=Mock(return_value=types.SimpleNamespace(status_code=200,text='{}',json=lambda:{}))
        res=ns['send_one'](None,'d','https://host','p',('key','secret'),5,'delivery')
        self.assertEqual(res['outcome'],'ACCEPTED')
        self.assertEqual(ns['requests'].post.call_args.kwargs['data'],b'{"original":true}')
    def test_observation_page_cap_fails_closed(self):
        for filename,index,fn,args in [('05b_sender.sql',1,'read_observations',('h',None,'t','s','e')),('05d_verify_semantics.sql',0,'read_all',('h',None,'t'))]:
            ns=body(filename,index)
            ns['requests'].get=Mock(return_value=types.SimpleNamespace(status_code=200,json=lambda:{'data':[{'id':'a'}],'meta':{'cursor':'next'}}))
            data,error=ns[fn](*args)
            self.assertIsNone(data);self.assertIn('pagination',error)
    def test_orphan_recovered_from_saved_values(self):
        ns=body('05b_sender.sql'); saved=('score','trace','root','snowflake.token_credits',0.123,'NUMERIC','2026-10-13T10:00:00Z','saved')
        def q(session,sql,params=None):
            if 'SELECT max_traces_per_run' in sql:return [ns['DEFAULT_LIMITS']]
            if 'SELECT langfuse_host' in sql:return [('https://host','p',True,None,5)]
            if 'CURRENT_ACCOUNT()' in sql:return [('account',)]
            if 'SELECT s.score_id' in sql:return [saved]
            return []
        ns['q']=q;ns['enqueue']=Mock(return_value='delivery')
        ns['_snowflake'].get_username_password=lambda _:types.SimpleNamespace(username='key',password='secret')
        ns['requests'].get=Mock(return_value=types.SimpleNamespace(status_code=200,json=lambda:{'data':[{'id':'p'}]}))
        result=ns['run'](None,'d',20,False)
        payload=ns['enqueue'].call_args.args[-2]
        self.assertEqual(payload,dict(zip(['id','traceId','observationId','name','value','dataType','timestamp','comment'],saved)))
        self.assertEqual(result['ensured_score_deliveries'],1)

class Readback(unittest.TestCase):
    def test_reconciler_does_not_read_changed_project(self):
        ns=body('05b_sender.sql',1)
        def q(session,sql,params=None):
            if 'SELECT langfuse_host' in sql:return [('https://host','p')]
            return [('delivery','UNCERTAIN','trace','{}','https://host','other','start','end')]
        ns['q']=q
        ns['_snowflake'].get_username_password=lambda _:types.SimpleNamespace(username='key',password='secret')
        ns['requests'].get=Mock(return_value=types.SimpleNamespace(status_code=200,json=lambda:{'data':[{'id':'p'}]}))
        ns['read_observations']=Mock(side_effect=AssertionError('wrong project read'))
        self.assertFalse(ns['run'](None,'d',20)['ok'])
        ns['read_observations'].assert_not_called()
    def test_score_rejects_wrong_subject_duplicates_or_truncation(self):
        ns=body('05c_verify_scores.sql')
        def sql(query,params=None):
            rows=[('https://host','trace','root','credits',1,'p')] if 'FROM '+ns['DB']+'.SCORES' in query else [('https://host','p')]
            return types.SimpleNamespace(collect=lambda:rows)
        session=types.SimpleNamespace(sql=sql)
        ns['_snowflake'].get_username_password=lambda _:types.SimpleNamespace(username='key',password='secret')
        valid={'id':'score','name':'credits','value':1,'dataType':'NUMERIC','subject':{'kind':'observation','id':'root','traceId':'trace'}}
        for data,meta,expected in [([valid],{},True),([valid,valid],{},False),
                ([dict(valid,subject={'kind':'trace','id':'root','traceId':'trace'})],{},False),
                ([dict(valid,dataType='BOOLEAN')],{},False),([valid],{'cursor':'next'},False)]:
            responses=[types.SimpleNamespace(status_code=200,json=lambda:{'data':[{'id':'p'}]}),
                       types.SimpleNamespace(status_code=200,json=lambda:{'data':data,'meta':meta})]
            ns['requests'].get=Mock(side_effect=responses)
            self.assertEqual(ns['run'](session,'d','score')['ok'],expected)
    def test_existing_delivery_is_not_reenqueued(self):
        ns=body('05b_sender.sql'); conn=sqlite3.connect(':memory:')
        conn.executescript("""CREATE TABLE SCORES(score_id,destination_id,host,project_id,trace_id,observation_id,name,value,data_type,score_ts,comment,created_at);
        CREATE TABLE DELIVERIES(destination_id,item_type,item_key,status);
        INSERT INTO SCORES VALUES ('s','d','https://host','p','t','root','credits',1,'NUMERIC','ts','comment','ts');
        INSERT INTO DELIVERIES VALUES ('d','BILLING_SCORE','s','ACCEPTED');""")
        def q(session,sql,params=None):
            if 'SELECT max_traces_per_run' in sql:return [ns['DEFAULT_LIMITS']]
            if 'SELECT langfuse_host' in sql:return [('https://host','p',True,None,5)]
            if 'CURRENT_ACCOUNT()' in sql:return [('account',)]
            if 'SELECT s.score_id' in sql:return conn.execute(sql.replace(ns['DB']+'.',''),params).fetchall()
            return []
        ns['q']=q;ns['enqueue']=Mock(side_effect=AssertionError('duplicate enqueue'))
        ns['_snowflake'].get_username_password=lambda _:types.SimpleNamespace(username='key',password='secret')
        ns['requests'].get=Mock(return_value=types.SimpleNamespace(status_code=200,json=lambda:{'data':[{'id':'p'}]}))
        for state in ['ACCEPTED','UNCERTAIN','PENDING','RETRYABLE','REJECTED']:
            conn.execute('UPDATE DELIVERIES SET status=?',(state,))
            self.assertEqual(ns['run'](None,'d',20,False)['ensured_score_deliveries'],0)
        ns['enqueue'].assert_not_called()


class Syntax(unittest.TestCase):
    def test_all_python_handlers_parse(self):
        for file in SQL.glob('*.sql'):
            for b in file.read_text().split('$$')[1::2]:
                if b.lstrip().startswith('import '): ast.parse(b,filename=file.name)

if __name__=='__main__': unittest.main()
