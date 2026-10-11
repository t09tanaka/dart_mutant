import 'dart:convert';

import 'json.dart';
import 'version.dart';

/// The version of the viewer the page loads: the `mutation-test-report-app`
/// element of the npm package `mutation-testing-elements`. Pinned, so that a
/// report that was written once is shown the same way later.
const viewerVersion = '3.9.0';

/// Where the page loads the viewer from.
const viewerUrl =
    'https://cdn.jsdelivr.net/npm/mutation-testing-elements@$viewerVersion'
    '/dist/mutation-test-elements.js';

/// The hash of the file at [viewerUrl] (subresource integrity): a browser
/// does not run a script from there that is not this file.
const viewerIntegrity =
    'sha384-/dXYuoYRvO6rJ0FNtdKR+Hmq5iGrkkSDpc/TGgbSoReog26ZqhLhpSt4l+0Wwew2';

/// What marks a page as one of this tool's, see [isHtmlReport].
const _generator = '<meta name="generator" content="dart_mutant ';

const _escapes = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};

/// [text] as text of an HTML page, or as the value of an attribute.
String escapeHtml(String text) =>
    text.replaceAllMapped(RegExp('[&<>"\']'), (match) => _escapes[match[0]]!);

/// [value] as JSON that can stand in a `<script>` element.
///
/// The HTML parser ends a script at `</script>` and treats `<!--` in it
/// specially, wherever they are, also inside a string of the script: the
/// source of a mutated file can hold both. Every `<` is therefore written
/// as its escape, which only ever occurs inside a JSON string. The two line
/// separators that JSON allows in a string and older JavaScript does not
/// are written the same way.
String jsonForScript(Object? value) => jsonEncode(value)
    .replaceAll('<', r'\u003c')
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');

/// The page that shows [report] (as `buildReport` makes it): the report is
/// in the page, and the viewer is loaded from [viewerUrl], so the page is
/// one file that needs a connection to that address when it is opened.
///
/// Without the viewer (no connection, or a file there that is not the one
/// of [viewerIntegrity]) the page says so instead of staying empty.
String htmlReport(JsonObject report, {String title = 'Mutation report'}) =>
    '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
$_generator$packageVersion">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
  body { margin: 0; }
  #viewer-missing { font: 16px/1.5 sans-serif; margin: 2em; max-width: 40em; }
</style>
</head>
<body>
<mutation-test-report-app title-postfix="${escapeHtml(title)}"></mutation-test-report-app>
<script src="$viewerUrl" integrity="$viewerIntegrity" crossorigin="anonymous"></script>
<script>
  const app = document.querySelector('mutation-test-report-app');
  app.addEventListener('theme-changed', (event) => {
    document.body.style.backgroundColor = event.detail.themeBackgroundColor;
  });
  app.report = ${jsonForScript(report)};
  if (!customElements.get('mutation-test-report-app')) {
    const note = document.createElement('p');
    note.id = 'viewer-missing';
    note.textContent =
      'The viewer of this report could not be loaded from $viewerUrl. ' +
      'Open the page with a connection to that address. The report itself ' +
      'is in this file, and in the JSON file next to it.';
    document.body.append(note);
  }
</script>
</body>
</html>
''';

/// True when [text] is a page as [htmlReport] writes it: `--html` replaces
/// such a file, and no other. A file that only quotes the mark of such a
/// page (a source, a note) is none.
bool isHtmlReport(String text) =>
    text.startsWith('<!DOCTYPE html>\n') && text.contains(_generator);
