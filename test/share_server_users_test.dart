import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notilus/services/sharing/share_server_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stand-in for the OS keychain, so the controller's password handling can be
/// exercised without one.
class _FakeKeychain {
  final Map<String, String> values = {};

  static const _channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final key = '${args['key'] ?? ''}';
      switch (call.method) {
        case 'write':
          values[key] = '${args['value']}';
          return null;
        case 'read':
          return values[key];
        case 'delete':
          values.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(values);
        case 'deleteAll':
          values.clear();
          return null;
        case 'containsKey':
          return values.containsKey(key);
      }
      return null;
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeKeychain keychain;

  setUp(() {
    keychain = _FakeKeychain()..install();
    SharedPreferences.setMockInitialValues({});
  });

  test('a fresh install already has the machine account', () async {
    final controller = ShareServerController.instance;
    await controller.load();

    expect(controller.users, hasLength(1));
    final user = controller.users.single;
    expect(user.name, ShareServerController.machineUserName);
    expect(user.generated, isTrue, reason: 'its password was invented here');

    final password = await controller.passwordFor(user.name);
    expect(password, isNotNull);
    expect(password, isNot(isEmpty));
    expect(keychain.values.values, contains(password));
  });

  test('the invented password is typeable and unique per install', () {
    final made = {
      for (var i = 0; i < 50; i++) ShareServerController.debugInventPassword(),
    };
    expect(made, hasLength(50), reason: 'no two installs share a password');
    for (final password in made) {
      expect(password, matches(RegExp(r'^[a-z2-9]{4}(-[a-z2-9]{4}){3}$')));
      // Characters that are read wrong off a screen are left out.
      expect(password, isNot(contains(RegExp(r'[ilo01]'))));
    }
  });
}
