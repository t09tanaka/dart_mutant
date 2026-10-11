import 'dart:convert';
import 'dart:io';

/// Where the programs the tests start are kept between runs. `.dart_tool`
/// is ignored by git and is not part of the published package.
const _cache = '.dart_tool/dart_mutant_test';

int _hash(List<int> bytes) {
  // FNV-1a, 32 bit: a name for the cache, nothing more.
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// A directory of this call's own below [_cache]. The test files are run
/// at the same time, as isolates of one process: the process id is no name
/// to tell them apart by.
Directory _workspace() {
  Directory(_cache).createSync(recursive: true);
  return Directory(_cache).createTempSync('compile_');
}

/// `dart compile <arguments> -o <output>`.
void _compile(List<String> arguments, String output) {
  final result = Process.runSync(Platform.resolvedExecutable, [
    'compile',
    ...arguments,
    '-o',
    output,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'dart compile ${arguments.join(' ')} failed:\n'
      '${result.stdout}${result.stderr}',
    );
  }
}

/// The stand-in for the test runner (test/fixtures/run/fake_test.dart.txt)
/// as a program of its own: the absolute path of the executable.
///
/// The stand-in for the test runner (test/fixtures/run/fake_test.dart.txt)
/// as a program of its own: the absolute path of the executable.
///
/// A run of `dart_mutant` in these tests starts it once per mutant. From
/// source that is a start of the Dart compiler each time; compiled once, a
/// start costs a few milliseconds. It is compiled again when its source or
/// the SDK changes.
String compiledFake() {
  const source = 'test/fixtures/run/fake_test.dart.txt';
  final key = _hash([
    ...File(source).readAsBytesSync(),
    ...utf8.encode(Platform.version),
  ]).toRadixString(16);
  final output = File(
    '$_cache/fake_test_$key${Platform.isWindows ? '.exe' : ''}',
  ).absolute;
  if (!output.existsSync()) {
    // Compiled in a directory of its own and then renamed: no test file
    // starts a program that another is still writing, and two that compile
    // at the same time end with the same program under the one name.
    final workspace = _workspace();
    try {
      // The compiler wants a name that ends in .dart.
      final copy = File('${workspace.path}/fake_test.dart')
        ..writeAsBytesSync(File(source).readAsBytesSync());
      final compiled = '${workspace.path}/fake_test.out';
      _compile(['exe', copy.path], compiled);
      File(compiled).renameSync(output.path);
    } finally {
      workspace.deleteSync(recursive: true);
    }
  }
  return output.path;
}

/// The command line of this package (bin/dart_mutant.dart) compiled to a
/// kernel file, for a test file that starts it as a process of its own.
///
/// Compiled once per test file, every time: what is started is the code as
/// it is now, without a compiler in front of every start.
class CompiledCommandLine {
  CompiledCommandLine() : _directory = _workspace() {
    try {
      _compile(['kernel', 'bin/dart_mutant.dart'], _kernel);
    } on StateError {
      delete();
      rethrow;
    }
  }

  final Directory _directory;

  String get _kernel =>
      File('${_directory.path}/dart_mutant.dill').absolute.path;

  /// The arguments for `dart` that run the command line.
  List<String> get arguments => [_kernel];

  /// Removes the kernel file.
  void delete() => _directory.deleteSync(recursive: true);
}
