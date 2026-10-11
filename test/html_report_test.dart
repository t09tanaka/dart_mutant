import 'dart:convert';

import 'package:dart_mutant/src/html_report.dart';
import 'package:dart_mutant/src/version.dart';
import 'package:test/test.dart';

/// The report that is in a page, as a browser reads it: the text between
/// `app.report = ` and the end of that statement, as JSON.
Object? reportIn(String page) => jsonDecode(
  RegExp(r'^  app\.report = (.*);$', multiLine: true).firstMatch(page)![1]!,
);

void main() {
  const report = {
    'schemaVersion': '2',
    'files': {
      'lib/a.dart': {
        'source': "// </script><!-- <b>&amp;\u2028\u2029\nvar a = '\\n';\n",
        'mutants': <Object?>[],
      },
    },
  };

  group('jsonForScript', () {
    test('no "<" is left, so nothing ends the script or opens a comment', () {
      final text = jsonForScript(report);
      expect(text, isNot(contains('<')));
      expect(text, contains(r'// \u003c/script>\u003c!-- \u003cb>&amp;'));
      expect(jsonDecode(text), report);
    });

    test('the line separators JSON allows in a string are escaped', () {
      final text = jsonForScript('a\u2028b\u2029c');
      expect(text, r'"a\u2028b\u2029c"');
      expect(jsonDecode(text), 'a\u2028b\u2029c');
    });

    test('what needs no escape is the JSON it was', () {
      expect(
        jsonForScript({'a': 1, 'b': 'x > y & z'}),
        '{"a":1,"b":"x > y & z"}',
      );
    });
  });

  group('escapeHtml', () {
    test('the five characters that mean something in a page', () {
      expect(
        escapeHtml('''<a href="x" title='y'>&</a>'''),
        '&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;&lt;/a&gt;',
      );
    });

    test('anything else is left as it is', () {
      expect(escapeHtml('a b/c=d;é'), 'a b/c=d;é');
    });
  });

  group('htmlReport', () {
    final page = htmlReport(report);

    test('the report is in the page, as it was given', () {
      expect(reportIn(page), report);
    });

    test('the only scripts are the viewer and the one with the report', () {
      expect('<script'.allMatches(page), hasLength(2));
      expect('</script>'.allMatches(page), hasLength(2));
      expect(page, isNot(contains('<!--')));
    });

    test('the viewer is loaded from one pinned address, with its hash', () {
      expect(
        page,
        contains(
          '<script src="https://cdn.jsdelivr.net/npm/'
          'mutation-testing-elements@3.9.0/dist/mutation-test-elements.js" '
          'integrity="$viewerIntegrity" crossorigin="anonymous"></script>',
        ),
      );
      expect(viewerUrl, contains('@$viewerVersion/'));
      expect(viewerIntegrity, startsWith('sha384-'));
      // The page says where the viewer should have come from when it did
      // not come.
      expect(page, contains("could not be loaded from $viewerUrl. '"));
    });

    test('the page is a whole document that says what wrote it', () {
      expect(page, startsWith('<!DOCTYPE html>\n<html lang="en">\n'));
      expect(page, endsWith('</body>\n</html>\n'));
      expect(page, contains('<meta charset="utf-8">'));
      expect(
        page,
        contains(
          '<meta name="generator" content="dart_mutant $packageVersion">',
        ),
      );
      expect(page, contains('<title>Mutation report</title>'));
      expect(
        page,
        contains(
          '<mutation-test-report-app title-postfix="Mutation report">'
          '</mutation-test-report-app>',
        ),
      );
    });

    test('the title is text, not markup', () {
      final titled = htmlReport(report, title: 'a <b> & "c"');
      expect(
        titled,
        contains('<title>a &lt;b&gt; &amp; &quot;c&quot;</title>'),
      );
      expect(
        titled,
        contains('title-postfix="a &lt;b&gt; &amp; &quot;c&quot;">'),
      );
      expect(reportIn(titled), report);
    });
  });

  group('isHtmlReport', () {
    test('a page of this tool, of any version', () {
      expect(isHtmlReport(htmlReport(report)), isTrue);
      expect(
        isHtmlReport(htmlReport(report).replaceFirst(packageVersion, '9.9.9')),
        isTrue,
      );
    });

    test('any other file is not', () {
      expect(isHtmlReport(''), isFalse);
      expect(isHtmlReport('<html><body>dart_mutant</body></html>'), isFalse);
      expect(
        isHtmlReport('<meta name="generator" content="another tool">'),
        isFalse,
      );
      expect(isHtmlReport(jsonEncode(report)), isFalse);
      // A file that quotes the mark, and a page behind something else.
      expect(
        isHtmlReport('<meta name="generator" content="dart_mutant 9.9.9">'),
        isFalse,
      );
      expect(
        isHtmlReport(
          "const mark = '<meta name=\"generator\" "
          "content=\"dart_mutant ';",
        ),
        isFalse,
      );
      expect(isHtmlReport(' ${htmlReport(report)}'), isFalse);
      expect(isHtmlReport('<!DOCTYPE html>\n<html></html>\n'), isFalse);
    });
  });
}
