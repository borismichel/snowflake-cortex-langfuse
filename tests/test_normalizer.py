import unittest

class NormalizerFixtures(unittest.TestCase):
    def test_original_eleven_fixtures_and_known_boundary(self):
        import ast,json,re
        from pathlib import Path
        src=Path(__file__).resolve().parents[1] / 'sql'
        report={'scope':'Offline checks only; no Snowflake execution or external requests','python_bodies':[],'normalizer_fixtures':[]}
        ns={}
        for p in sorted(src.glob('*.sql')):
         if p.name not in ['01_role_warehouse_database.sql','02_core_tables.sql','02b_migration_v2.sql','03_network_secret_integration.sql','04_staging_routing.sql','05_message_normalizer.sql','05a_payload_builder.sql','05b_sender.sql','05c_verify_scores.sql','05d_verify_semantics.sql','07_tasks_status.sql','99_uninstall.sql']:continue
         parts=p.read_text().split('$$')
         for i in range(1,len(parts),2):
          body=parts[i]
          if not body.lstrip().startswith('import '):continue
          ast.parse(body)
          report['python_bodies'].append({'file':p.name,'result':'syntax PASS'})
          if p.name=='05_message_normalizer.sql':exec(compile(body,p.name,'exec'),ns)
        s=(src/'05_message_normalizer.sql').read_text()
        fixtures=re.findall(r"\('([^']+)', '([^']+)',\s*'((?:[^']|'')*)'\)",s)
        assert len(fixtures)==11,len(fixtures)
        for name,rec,raw in fixtures:
         attrs=json.loads(raw.replace('\\\\','\\').replace("''","'"));n=ns['normalize'](rec,attrs)
         if name=='structured':ok=n['input'][1]['role']=='assistant' and n['output']['content']=='ok'
         elif name=='flattened_history':ok=[m['role'] for m in n['input']]==['user','assistant','user'] and n['input'][1]['content']=='earlier reply'
         elif name=='reminders_and_question':ok=n['input'][0]['role']=='system' and n['input'][1]['content']=='What is X?' and n['meta']['n_system_reminder_blocks']==2
         elif name=='quoted_tag_only':ok=n['input'][0]['content']=='What does <system-reminder> mean?' and n['meta']['ambiguous'][0]['issue']=='reminder_tag_not_leading'
         elif name=='reminder_then_quoted_tag':ok=n['input'][1]['role']=='user' and '</system-reminder>' in n['input'][1]['content']
         elif name.startswith('unknown_'):ok=n['meta']['message_format']=='unknown' and 'unparsed_source_messages' in n['input']
         elif name=='tool_selection_output':ok=n['output']['content'] is None and n['output']['tool_calls'][0]['id']=='c2' and json.loads(n['output']['tool_calls'][0]['function']['arguments'])['sql']=='SELECT 1'
         elif name=='tool_execution_input':ok=n['input'][1]['tool_calls'][0]['id']==n['input'][2]['tool_call_id']=='c1' and n['input'][2]['content']=='RESULT' and n['output'] is None
         elif name=='tool_length_mismatch':ok=n['output'] is None and n['meta']['tool_issues']==['tool_selection_array_length_mismatch']
         elif name=='non_model_span':ok=n=={}
         assert ok,name
         report['normalizer_fixtures'].append({'case':name,'result':'PASS'})
        # Boundary probe: complete leading user-authored tag is indistinguishable from injected context.
        x=ns['normalize']('ReasoningAgentStepPlanning-0',{ns['P']+'messages':['User: <system-reminder>quoted example</system-reminder> Explain this markup.']})
        report['leading_literal_tag_probe']={'roles':[m['role'] for m in x['input']],'ambiguous':x['meta']['ambiguous'],'result':'limitation reproduced: leading complete literal block classified as system without ambiguity'}
