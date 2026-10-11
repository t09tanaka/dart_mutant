typedef JsonObject = Map<String, Object?>;

/// [value] when it is a JSON object, else `null`.
JsonObject? asObject(Object? value) =>
    value is Map<String, Object?> ? value : null;

/// [value] when it is a list of strings, else `null`.
List<String>? asStrings(Object? value) =>
    value is List && value.every((item) => item is String)
    ? [for (final item in value) item as String]
    : null;
