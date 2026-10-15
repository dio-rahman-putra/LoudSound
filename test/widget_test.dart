import 'package:flutter_test/flutter_test.dart';
import 'package:iot_loud_sound/main.dart';

void main() {
  testWidgets('dashboard shows placeholder readings and noise categories',
      (WidgetTester tester) async {
    await tester.pumpWidget(const LoudSoundApp());

    expect(find.text('LOUDSOUND'), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
    expect(find.text('dB'), findsOneWidget);
    expect(find.text('Belum terhubung'), findsOneWidget);
    expect(find.text('Menunggu data dari sensor'), findsOneWidget);
    expect(find.text('Pelan'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('Berisik'), findsOneWidget);
  });

  testWidgets('notification button explains Firebase setup is required',
      (WidgetTester tester) async {
    await tester.pumpWidget(const LoudSoundApp());
    await tester.tap(find.byTooltip('Aktifkan notifikasi'));
    await tester.pumpAndSettle();

    expect(
      find.text('Firebase belum dikonfigurasi. Ikuti langkah di README.md.'),
      findsOneWidget,
    );
  });
}
