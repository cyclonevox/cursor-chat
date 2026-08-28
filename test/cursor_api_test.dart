import 'dart:convert';
import 'dart:io';

import 'package:cursor_chat/api/cursor_api.dart';
import 'package:cursor_chat/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late CursorApi api;
  Map<String, dynamic>? lastCreateBody;

  setUp(() async {
    lastCreateBody = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      Future<void> sendJson(int status, Map<String, dynamic> body) async {
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
        await req.response.close();
      }

      if (req.method == 'GET' && path == '/v1/models') {
        await sendJson(200, {
          'items': [
            {
              'id': 'composer-2.5',
              'displayName': 'Composer 2.5',
              'parameters': [
                {
                  'id': 'fast',
                  'displayName': 'Fast',
                  'values': [
                    {'value': 'false'},
                    {'value': 'true', 'displayName': 'Fast'},
                  ],
                },
              ],
            },
          ],
        });
        return;
      }
      if (req.method == 'POST' && path == '/v1/agents') {
        final raw = await utf8.decoder.bind(req).join();
        lastCreateBody = jsonDecode(raw) as Map<String, dynamic>;
        await sendJson(200, {
          'agent': {'id': 'bc-test', 'name': '讲解这道题', 'status': 'ACTIVE'},
          'run': {'id': 'run-1', 'agentId': 'bc-test', 'status': 'CREATING'},
        });
        return;
      }
      if (req.method == 'POST' && path == '/v1/agents/bc-test/runs') {
        await sendJson(200, {
          'run': {'id': 'run-2', 'agentId': 'bc-test', 'status': 'CREATING'},
        });
        return;
      }
      if (req.method == 'GET' && path == '/v1/agents/bc-test') {
        await sendJson(200, {
          'id': 'bc-test',
          'name': '讲解这道题',
          'status': 'ACTIVE',
          'latestRunId': 'run-1',
        });
        return;
      }
      if (req.method == 'GET' &&
          path == '/v1/agents/bc-test/runs/run-drop/stream') {
        req.response.statusCode = 200;
        req.response.headers.set(
          'Content-Type',
          'text/event-stream; charset=utf-8',
        );
        await req.response.close();
        return;
      }
      if (req.method == 'GET' &&
          path == '/v1/agents/bc-test/runs/run-gone/stream') {
        await sendJson(409, {
          'error': {
            'code': 'stream_unavailable',
            'message': 'Run stream is no longer available',
          },
        });
        return;
      }
      if (req.method == 'GET' && path == '/v1/agents/bc-test/runs/run-gone') {
        await sendJson(200, {
          'id': 'run-gone',
          'agentId': 'bc-test',
          'status': 'FINISHED',
          'result': 'jian-10 loadout',
        });
        return;
      }
      if (req.method == 'GET' && path == '/v1/agents/bc-test/runs/run-drop') {
        await sendJson(200, {
          'id': 'run-drop',
          'agentId': 'bc-test',
          'status': 'FINISHED',
          'result': 'polled after drop',
        });
        return;
      }
      if (req.method == 'GET' &&
          path == '/v1/agents/bc-test/runs/run-410/stream') {
        req.response.statusCode = 410;
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && path == '/v1/agents/bc-test/runs/run-410') {
        await sendJson(200, {
          'id': 'run-410',
          'agentId': 'bc-test',
          'status': 'FINISHED',
          'result': 'gone via 410',
        });
        return;
      }
      if (req.method == 'GET' &&
          path == '/v1/agents/bc-test/runs/run-error/stream') {
        req.response.statusCode = 200;
        req.response.headers.set(
          'Content-Type',
          'text/event-stream; charset=utf-8',
        );
        req.response.add(
          utf8.encode(
            'event: status\ndata: {"runId":"run-error","status":"RUNNING"}\n\n'
            'event: status\ndata: {"runId":"run-error","status":"ERROR"}\n\n'
            'event: result\ndata: {"runId":"run-error","status":"ERROR"}\n\n'
            'event: done\ndata: {}\n\n',
          ),
        );
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && path == '/v1/agents/bc-test/runs/run-error') {
        await sendJson(200, {
          'id': 'run-error',
          'agentId': 'bc-test',
          'status': 'ERROR',
          'result': null,
          'error': null,
        });
        return;
      }
      if (req.method == 'GET' &&
          path == '/v1/agents/bc-test/runs/run-error-poll/stream') {
        req.response.statusCode = 410;
        await req.response.close();
        return;
      }
      if (req.method == 'GET' &&
          path == '/v1/agents/bc-test/runs/run-error-poll') {
        await sendJson(200, {
          'id': 'run-error-poll',
          'agentId': 'bc-test',
          'status': 'ERROR',
          'result': null,
        });
        return;
      }
      if (req.method == 'GET' &&
          path == '/v1/agents/bc-test/runs/run-1/stream') {
        req.response.statusCode = 200;
        req.response.headers.set(
          'Content-Type',
          'text/event-stream; charset=utf-8',
        );
        req.response.add(
          utf8.encode(
            'event: status\ndata: {"runId":"run-1","status":"RUNNING"}\n\n'
            'event: assistant\ndata: {"text":"because "}\n\n'
            'event: assistant\ndata: {"text":"common denominator."}\n\n'
            'event: result\ndata: {"runId":"run-1","status":"FINISHED","text":"because common denominator."}\n\n'
            'event: done\ndata: {}\n\n',
          ),
        );
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    api = CursorApi(
      apiKey: 'test-key',
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('listModels', () async {
    final models = await api.listModels();
    expect(models.single.id, 'composer-2.5');
    expect(models.single.parameters.single.id, 'fast');
  });

  test('createAgent sends only selected model params', () async {
    await api.createAgent(
      text: 'hi',
      modelId: 'composer-2.5',
      modelParams: [
        {'id': 'fast', 'value': 'false'},
      ],
    );
    expect(lastCreateBody?['model'], {
      'id': 'composer-2.5',
      'params': [
        {'id': 'fast', 'value': 'false'},
      ],
    });
  });

  test('createAgent and stream assistant text', () async {
    final created = await api.createAgent(text: '这题为啥这样做？');
    expect(created.agentId, 'bc-test');
    expect(created.runId, 'run-1');
    final deltas = <String>[];
    final text = await api.streamRun(
      agentId: created.agentId,
      runId: created.runId,
      onDelta: deltas.add,
    );
    expect(deltas, ['because ', 'common denominator.']);
    expect(text, 'because common denominator.');
  });

  test('createAgent sends name and client agentId', () async {
    await api.createAgent(
      text: 'hi',
      name: '这题为啥要通分',
      agentId: 'bc-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    );
    expect(lastCreateBody?['name'], '这题为啥要通分');
    expect(
      lastCreateBody?['agentId'],
      'bc-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    );
  });

  test('createRun follow-up', () async {
    final runId = await api.createRun(agentId: 'bc-test', text: '再讲细一点');
    expect(runId, 'run-2');
  });

  test('streamRun falls back to polling when the socket drops', () async {
    final text = await api.streamRun(
      agentId: 'bc-test',
      runId: 'run-drop',
      onDelta: (_) {},
    );
    expect(text, 'polled after drop');
  });

  test('streamRun polls when the SSE stream is already gone', () async {
    final text = await api.streamRun(
      agentId: 'bc-test',
      runId: 'run-gone',
      onDelta: (_) {},
    );
    expect(text, 'jian-10 loadout');
  });

  test('streamRun polls after HTTP 410', () async {
    final text = await api.streamRun(
      agentId: 'bc-test',
      runId: 'run-410',
      onDelta: (_) {},
    );
    expect(text, 'gone via 410');
  });

  test('stream_unavailable is treated as a finished stream', () {
    expect(
      CursorApiException(
        409,
        '{"error":{"code":"stream_unavailable"}}',
      ).isStreamGone,
      isTrue,
    );
    expect(CursorApiException(410, '').isStreamGone, isTrue);
    expect(CursorApiException(409, 'agent_busy').isStreamGone, isFalse);
  });

  test('streamRun throws when the run status is ERROR', () async {
    try {
      await api.streamRun(
        agentId: 'bc-test',
        runId: 'run-error',
        onDelta: (_) {},
      );
      fail('expected RunFailedException');
    } on RunFailedException catch (e) {
      expect(e.status, 'ERROR');
    }
  });

  test('polling an ERROR run does not become 运行结束：ERROR', () async {
    try {
      await api.streamRun(
        agentId: 'bc-test',
        runId: 'run-error-poll',
        onDelta: (_) {},
      );
      fail('expected RunFailedException');
    } on RunFailedException catch (e) {
      expect(e.status, 'ERROR');
      expect(e.userMessage.contains('运行结束'), isFalse);
    }
  });

  test('waitForRunText throws instead of returning 运行结束：ERROR', () async {
    try {
      await api.waitForRunText('bc-test', 'run-error');
      fail('expected RunFailedException');
    } on RunFailedException catch (e) {
      expect(e.status, 'ERROR');
    }
  });
}
