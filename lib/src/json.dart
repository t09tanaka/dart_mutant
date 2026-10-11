typedef JsonObject = Map<String, Object?>;

/// [value] when it is a JSON object, else `null`.
JsonObject? asObject(Object? value) =>
    value is Map<String, Object?> ? value : null;

/// [value] when it is a list of strings, else `null`.
List<String>? asStrings(Object? value) =>
    value is List && value.every((item) => item is String)
    ? [for (final item in value) item as String]
    : null;

/// True when [a] and [b] are the same JSON: objects with the same keys and
/// values in any order, lists with the same items in the same order, and
/// equal values otherwise.
bool sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && sameJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        a.indexed.every((item) => sameJson(item.$2, b[item.$1]));
  }
  return a == b;
}
