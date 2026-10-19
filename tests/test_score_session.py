"""Exercise score sends with a supplied HTTP session and persisted status."""
import json
import types
import unittest
from unittest.mock import Mock
from test_safety import body


class ScoreSession(unittest.TestCase):
    def test_reuses_session_and_persists_response_status(self):
        for status, expected in [(200, 'ACCEPTED'), (401, 'REJECTED'), (429, 'RETRYABLE')]:
            with self.subTest(status=status):
                ns = body('05b_sender.sql')
                calls = []
                def q(session, sql, params=None):
                    calls.append((sql, params))
                    if 'SELECT destination_id, host, project_id' in sql:
                        return [('dest', 'https://example.test', 'project')]
                    if "SET status = 'IN_FLIGHT'" in sql:
                        return [(1,)]
                    if 'SELECT item_type, TO_JSON(payload)' in sql:
                        return [('BILLING_SCORE', json.dumps({'id': 'score'}), 1, 'trace')]
                    return []
                ns['q'] = q
                ns['requests'].exceptions = types.SimpleNamespace(ConnectTimeout=TimeoutError)
                ns['requests'].post = Mock(side_effect=AssertionError('shared session bypassed'))
                client = types.SimpleNamespace(post=Mock(return_value=types.SimpleNamespace(
                    status_code=status, text='{}', json=lambda: {})))
                result = ns['send_one'](None, 'dest', 'https://example.test', 'project', ('public', 'secret'), 5, 'delivery', client)
                client.post.assert_called_once()
                ns['requests'].post.assert_not_called()
                self.assertEqual(result['http'], status)
                self.assertEqual(result['outcome'], expected)
                persisted = [p for sql, p in calls if 'UPDATE LANGFUSE_EXPORTER.CORE.DELIVERIES SET status = ?' in sql]
                self.assertEqual(persisted[0][:2], [expected, status])
                self.assertEqual(any('paused_reason' in sql for sql, _ in calls), status == 401)
