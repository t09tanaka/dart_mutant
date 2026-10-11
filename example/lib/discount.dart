/// The price after a discount of [percent] percent, in cents. `null` when
/// there is no price to discount.
int? discounted(int? cents, int percent) {
  if (cents == null) {
    return null;
  }
  final rate = percent.clamp(0, 100);
  return (cents * (100 - rate) / 100).round();
}
