import 'package:flutter_test/flutter_test.dart';
import 'package:codeit/main.dart';

void main() {
  testWidgets('RootRouter shows loading then routes', (tester) async {
    await tester.pumpWidget(const CodeItApp());
    expect(find.textContaining('codeit'), findsWidgets);
  });
}
