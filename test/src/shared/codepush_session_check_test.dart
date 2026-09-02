import 'package:flutter_compile/src/commands/codepush_commands/_codepush_shared_args.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockClient extends Mock implements CodePushClient {}

void main() {
  group('sessionCheckForStatus', () {
    test('a 2xx is a working session', () {
      expect(
        CodePushClient.sessionCheckForStatus(200),
        SessionCheck.valid,
      );
      expect(
        CodePushClient.sessionCheckForStatus(204),
        SessionCheck.valid,
      );
    });

    test('401 and 403 are the only rejections', () {
      expect(CodePushClient.sessionCheckForStatus(401), SessionCheck.expired);
      expect(CodePushClient.sessionCheckForStatus(403), SessionCheck.expired);
    });

    test(
        'everything else is unknown — a server or network problem must '
        'never masquerade as a dead login', () {
      for (final status in [null, 0, 302, 404, 429, 500, 502, 503]) {
        expect(
          CodePushClient.sessionCheckForStatus(status),
          SessionCheck.unknown,
          reason: 'status $status',
        );
      }
    });
  });

  group('refuseOnExpiredSession', () {
    late _MockLogger logger;
    late _MockClient client;

    setUp(() {
      logger = _MockLogger();
      client = _MockClient();
      when(() => logger.err(any())).thenReturn(null);
      when(() => logger.detail(any())).thenReturn(null);
    });

    Future<int?> run() => refuseOnExpiredSession(
          client: client,
          token: 'tok',
          logger: logger,
        );

    test(
        'a rejected login ends the run before the build, naming the '
        'login command', () async {
      when(() => client.checkSession(token: any(named: 'token')))
          .thenAnswer((_) async => SessionCheck.expired);

      expect(await run(), ExitCode.software.code);
      verify(
        () => logger.err(any(that: contains('fcp codepush login'))),
      ).called(1);
    });

    test(
        'an unanswerable probe continues — the saving must not become a '
        'new way to refuse a build', () async {
      when(() => client.checkSession(token: any(named: 'token')))
          .thenAnswer((_) async => SessionCheck.unknown);

      expect(await run(), isNull);
      verifyNever(() => logger.err(any()));
    });

    test('an accepted login continues without a user-visible line', () async {
      when(() => client.checkSession(token: any(named: 'token')))
          .thenAnswer((_) async => SessionCheck.valid);

      expect(await run(), isNull);
      verifyNever(() => logger.err(any()));
    });

    test('the message says the check happened BEFORE the build', () {
      // The point of the feature: the operator must be able to tell
      // this run cost them nothing. A reword that drops it turns the
      // fix back into an ordinary 401.
      expect(kExpiredSessionMessage, contains('before the build'));
      expect(kExpiredSessionMessage, contains('fcp codepush login'));
    });
  });
}
