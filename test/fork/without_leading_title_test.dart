import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/ai_answer_card.dart';

void main() {
  test('strips a leading title and capitalises the rest', () {
    expect(withoutLeadingTitle('Brindle has the same spirit.', 'Brindle'), 'It has the same spirit.');
    expect(
      withoutLeadingTitle('moth-girl and the lantern: shares a team-up.', 'Moth-Girl and the Lantern'),
      'It shares a team-up.',
    );
    expect(withoutLeadingTitle("Owl's quiet opening lands.", 'Owl'), 'Quiet opening lands.');
  });

  test('leaves other lines alone', () {
    expect(withoutLeadingTitle('Brindled into one plot.', 'Brindle'), 'Brindled into one plot.');
    expect(withoutLeadingTitle('Nine episodes are waiting.', 'Orchard Street'), 'Nine episodes are waiting.');
    expect(withoutLeadingTitle('Brindle', 'Brindle'), 'Brindle');
  });
}
