/// What `ps` is asked for, see [processTree]: of every process its id, the
/// id of the process that started it, and the memory it holds (its
/// resident set, in units of 1024 bytes), without a header.
const processListing = ['-A', '-o', 'pid=,ppid=,rss='];

/// The processes that descend from [root] in [listing] (what `ps` printed
/// for [processListing]), and the memory that [root] and they hold
/// together, in kilobytes. A line that does not start with two numbers, or
/// has more or less than three fields, is left out; a third field that is
/// no number (a `ps` that prints `12m`) counts as nothing held, and the
/// process is still found below its parent: the tree is also what is ended
/// at a time limit.
({List<int> descendants, int kilobytes}) processTree(String listing, int root) {
  final children = <int, List<int>>{};
  final held = <int, int>{};
  for (final line in listing.split('\n')) {
    final fields = [
      for (final field in line.trim().split(RegExp(r'\s+')))
        int.tryParse(field),
    ];
    if (fields.length == 3 && fields[0] != null && fields[1] != null) {
      children.putIfAbsent(fields[1]!, () => []).add(fields[0]!);
      held[fields[0]!] = fields[2] ?? 0;
    }
  }
  // A set, walked while it grows: a process is in it once, whatever the
  // list says of who started whom, so the walk ends with the list.
  final tree = {root};
  for (var index = 0; index < tree.length; index++) {
    tree.addAll(children[tree.elementAt(index)] ?? const []);
  }
  return (
    descendants: tree.skip(1).toList(),
    kilobytes: tree.fold(0, (sum, pid) => sum + (held[pid] ?? 0)),
  );
}

/// How much memory the test run of one mutant, with the processes it
/// started, may hold, in kilobytes: twice the most the run without a mutant
/// held ([baseline]), plus one gigabyte.
///
/// Only a mutant that takes memory without end gets this far (a loop that
/// adds to a list and never stops). The time limit would end it as well,
/// but not before it has taken what the machine has.
int memoryLimit(int baseline) => baseline * 2 + 1024 * 1024;

/// [kilobytes] in megabytes, rounded up: for a message.
int megabytes(int kilobytes) => (kilobytes / 1024).ceil();

/// The `statusReason` of a mutant whose test run was ended because it held
/// more than [limit] kilobytes.
String overMemoryReason(int limit) =>
    'the test run used more than ${megabytes(limit)} MB of memory and was '
    'ended';
