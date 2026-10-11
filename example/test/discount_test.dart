import 'package:dart_mutant_example/discount.dart';
import 'package:test/test.dart';

void main() {
  test('a price is discounted by the percentage', () {
    expect(discounted(1000, 25), 750);
    expect(discounted(999, 50), 500);
  });

  test('no price, no discount', () {
    expect(discounted(null, 25), isNull);
  });

  test('the percentage stays between 0 and 100', () {
    expect(discounted(1000, 150), 0);
  });
}
