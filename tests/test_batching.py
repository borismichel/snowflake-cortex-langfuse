"""Exercise actual v1.2 handlers offline; no claims of Snowflake or live HTTP acceptance."""
import json
import types
import unittest
from unittest.mock import Mock, MagicMock
from test_safety import body


def payload(trace, spans=1, text='hello'):
    return {'resourceSpans':[{'resource':{'attributes':[]},'scopeSpans':[{'scope':{'name':'test'},'spans':[
        {'traceId':trace,'spanId':f'{i:016x}','name':text} for i in range(spans)]}]}]}


class Batching(unittest.TestCase):
    def setUp(self):
        self.ns=body('05b_sender.sql')
        self.limits=self.ns['limits_from'](self.ns['DEFAULT_LIMITS'])
    def items(self, count, spans=1, text='hello'):
        return [{'delivery_id':str(i),'payload':payload(f'{i:032x}',spans,text)} for i in range(count)]
    def test_multi_trace_preserves_trace_and_span_identity(self):
        items=self.items(5,3)
        batches,rejected=self.ns['pack_traces'](items,self.limits)
        self.assertFalse(rejected);self.assertEqual(len(batches),1)
        spans=[s for r in json.loads(batches[0][1])['resourceSpans'] for sc in r['scopeSpans'] for s in sc['spans']]
        self.assertEqual(len(spans),15);self.assertEqual(len({s['traceId'] for s in spans}),5)
    def test_trace_and_span_caps(self):
        for key,value,expected in [('max_traces_per_request',2,[2,2,1]),('max_spans_per_request',5,[2,2,1])]:
            limits=dict(self.limits,**{key:value})
            batches,rejected=self.ns['pack_traces'](self.items(5,2),limits)
            self.assertEqual([len(b[0]) for b in batches],expected);self.assertFalse(rejected)
    def test_exact_utf8_byte_boundary_and_overflow(self):
        items=self.items(3,text='€🙂'*40)
        pair=self.ns['encoded']({'resourceSpans':[r for x in items[:2] for r in x['payload']['resourceSpans']]})
        limits=dict(self.limits,max_request_bytes=len(pair))
        batches,_=self.ns['pack_traces'](items,limits)
        self.assertEqual([len(b[0]) for b in batches],[2,1]);self.assertEqual(len(batches[0][1]),len(pair))
        limits['max_request_bytes']-=1
        batches,_=self.ns['pack_traces'](items,limits)
        self.assertEqual([len(b[0]) for b in batches],[1,1,1])
    def test_oversized_and_malformed_trace_never_disappear(self):
        items=self.items(1,3)+[{'delivery_id':'invalid','payload':{'resourceSpans':[]}}]
        batches,rejected=self.ns['pack_traces'](items,dict(self.limits,max_spans_per_request=2))
        self.assertFalse(batches);self.assertEqual(len(rejected),2)
        self.assertIn('OVERSIZED_TRACE',rejected[0][1]);self.assertIn('INVALID_PAYLOAD',rejected[1][1])
    def test_invalid_limits_fail_closed(self):
        for values in [(0,100,1000,1000000,20,100,300), (1000,100,1000,99999999,20,100,300), (1,2)]:
            with self.assertRaises(ValueError):self.ns['limits_from'](values)
    def prepare_send(self, claim_count=2, mismatch=False, crash_finalize=False):
        items=self.items(2);wire=self.ns['pack_traces'](items,self.limits)[0][0][1];calls=[]
        def q(session,sql,params=None):
            calls.append((sql,params))
            if 'SELECT delivery_id, destination_id' in sql:
                return [(x['delivery_id'],'d','https://host','WRONG' if mismatch else 'p',json.dumps(x['payload'])) for x in items]
            if "SET status='IN_FLIGHT'" in sql:return [(claim_count,)]
            if crash_finalize and 'SET finished_at' in sql:raise RuntimeError('simulated persistence failure')
            return []
        self.ns['q']=q
        self.ns['requests'].exceptions=types.SimpleNamespace(ConnectTimeout=TimeoutError)
        http=types.SimpleNamespace(post=Mock(return_value=types.SimpleNamespace(status_code=200,text='{}',json=lambda:{})))
        return items,wire,calls,http
    def send(self, items,wire,http):
        return self.ns['send_trace_batch'](None,'d','https://host','p',('key','secret'),5,items,wire,http)
    def test_atomic_claim_and_bulk_updates(self):
        items,wire,calls,http=self.prepare_send()
        def post(*args,**kwargs):
            self.assertEqual(calls[-1][0],'COMMIT')
            self.assertTrue(any('INSERT INTO LANGFUSE_EXPORTER.CORE.HTTP_BATCHES' in s for s,p in calls))
            return types.SimpleNamespace(status_code=200,text='{}',json=lambda:{})
        http.post.side_effect=post
        result=self.send(items,wire,http)
        self.assertEqual(result['outcome'],'ACCEPTED');self.assertEqual(result['traces'],2)
        self.assertEqual(http.post.call_count,1);self.assertEqual(http.post.call_args.kwargs['data'],wire)
        self.assertEqual(sum(sql=='BEGIN TRANSACTION' for sql,_ in calls),2)
        self.assertEqual(calls[-1][0],'COMMIT')
    def test_incomplete_claim_rolls_back_without_post(self):
        items,wire,calls,http=self.prepare_send(claim_count=1)
        self.assertEqual(self.send(items,wire,http)['outcome'],'CLAIM_SKIPPED')
        self.assertEqual(calls[-1][0],'ROLLBACK');http.post.assert_not_called()
    def test_project_or_wire_change_blocks_entire_request(self):
        items,wire,calls,http=self.prepare_send(mismatch=True)
        self.assertEqual(self.send(items,wire,http)['outcome'],'HELD_IDENTITY_MISMATCH');http.post.assert_not_called()
        items,wire,calls,http=self.prepare_send()
        self.assertEqual(self.send(items,b'{}',http)['outcome'],'HELD_PAYLOAD_MISMATCH');http.post.assert_not_called()
    def test_partial_response_holds_all_members(self):
        items,wire,calls,http=self.prepare_send()
        http.post.return_value=types.SimpleNamespace(status_code=200,text='partial',json=lambda:{'partialSuccess':{'rejectedSpans':1}})
        self.assertEqual(self.send(items,wire,http)['outcome'],'PARTIAL')
        updates=[p for s,p in calls if '.DELIVERIES SET status=IFF' in s]
        self.assertEqual(updates[0][0],'PARTIAL')
        self.assertEqual(http.post.call_count,1)  # no split/replay on partial acceptance
    def test_read_timeout_and_crash_do_not_trigger_resend(self):
        items,wire,calls,http=self.prepare_send()
        http.post.side_effect=RuntimeError('connection lost after POST')
        self.assertEqual(self.send(items,wire,http)['outcome'],'UNCERTAIN')
        self.assertEqual(http.post.call_count,1)
        items,wire,calls,http=self.prepare_send(crash_finalize=True)
        with self.assertRaises(RuntimeError):self.send(items,wire,http)
        self.assertEqual(calls[-1][0],'ROLLBACK');self.assertEqual(http.post.call_count,1)
    def test_retryable_and_auth_failure(self):
        for code,outcome in [(429,'RETRYABLE'),(503,'RETRYABLE'),(401,'REJECTED'),(500,'UNCERTAIN')]:
            items,wire,calls,http=self.prepare_send()
            http.post.return_value=types.SimpleNamespace(status_code=code,text='error',json=lambda:{})
            self.assertEqual(self.send(items,wire,http)['outcome'],outcome)
            self.assertEqual(http.post.call_count,1)
            self.assertEqual(any('paused_reason' in s for s,p in calls),code==401)
    def test_invalid_success_acknowledgement_is_uncertain(self):
        for data in [[],{'partialSuccess':{'rejectedSpans':'oops'}},{'partialSuccess':{'rejectedSpans':-1}}]:
            r=types.SimpleNamespace(status_code=200,json=lambda:data)
            # An empty list is an invalid JSON response object, too.
            self.assertEqual(self.ns['classify_response']('TRACE_BATCH',r)[0],'UNCERTAIN')
    def test_orchestrator_separates_scores_and_limits_trace_requests(self):
        ns=self.ns;items=self.items(5)
        config=(10,2,1000,1000000,2,1,300)
        sql_seen=[]
        def q(session,sql,params=None):
            sql_seen.append(sql)
            if 'SELECT max_traces_per_run' in sql:return [config]
            if 'SELECT langfuse_host' in sql:return [('https://host','p',True,None,5)]
            if 'CURRENT_ACCOUNT()' in sql:return [('account',)]
            if 'SELECT delivery_id,TO_JSON(payload)' in sql:return [(i['delivery_id'],json.dumps(i['payload'])) for i in items]
            if "AND item_type='TRACE_BATCH'" in sql and 'LIMIT 1' in sql:return [('already-queued',)]
            if "AND item_type='BILLING_SCORE'" in sql:return [('score',)]
            return []
        ns['q']=q;ns['_snowflake'].get_username_password=lambda _:types.SimpleNamespace(username='k',password='s')
        ns['requests'].get=Mock(return_value=types.SimpleNamespace(status_code=200,json=lambda:{'data':[{'id':'p'}]}))
        ns['requests'].Session=MagicMock()
        ns['send_trace_batch']=Mock(return_value={'outcome':'ACCEPTED','http':200})
        ns['send_one']=Mock(return_value={'outcome':'ACCEPTED','http':200})
        result=ns['run'](None,'d',None,False)
        self.assertTrue(result['ok']);self.assertEqual(ns['send_trace_batch'].call_count,2)
        self.assertEqual(ns['send_one'].call_count,1)
        self.assertEqual([len(c.args[6]) for c in ns['send_trace_batch'].call_args_list],[2,2])
        # The final whole trace remains queued; bulk selection does not claim unsent groups.
        self.assertTrue(any('LIMIT 1' in q and "BILLING_SCORE" in q for q in sql_seen))
        self.assertTrue(any('NOT EXISTS' in q and 'snowflake.token_credits' in q and 'LIMIT 1' in q for q in sql_seen))

    def test_span_membership_insert_is_set_based(self):
        self.ns['q']=Mock(return_value=[])
        self.ns['enqueue'](None,'d','https://host','p','a','TRACE_BATCH','t','t',payload('t'),['s'+str(i) for i in range(1000)])
        calls=self.ns['q'].call_args_list
        member_calls=[c for c in calls if '.DELIVERY_ITEMS' in c.args[1]]
        self.assertEqual(len(member_calls),1);self.assertIn('FLATTEN',member_calls[0].args[1])
        self.assertEqual(calls[0].args[1],'BEGIN TRANSACTION');self.assertEqual(calls[-1].args[1],'COMMIT')
    def test_enqueue_failure_rolls_back_delivery_and_members(self):
        def q(session,sql,params=None):
            if '.DELIVERY_ITEMS' in sql:raise RuntimeError('insert failed')
            return []
        self.ns['q']=Mock(side_effect=q)
        with self.assertRaises(RuntimeError):self.ns['enqueue'](None,'d','h','p','a','TRACE_BATCH','t','t',payload('t'),['s'])
        self.assertEqual(self.ns['q'].call_args.args[1],'ROLLBACK')

if __name__=='__main__':unittest.main()
