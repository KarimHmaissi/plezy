import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/widgets/ai_answer_card.dart';

void main() {
  test('strips a leading title and capitalises the rest', () {
    expect(withoutLeadingTitle('Fuze has the same spirit.', 'Fuze'), 'It has the same spirit.');
    expect(
      withoutLeadingTitle('ant-man and the wasp: shares a team-up.', 'Ant-Man and the Wasp'),
      'It shares a team-up.',
    );
    expect(withoutLeadingTitle("Up's quiet opening lands.", 'Up'), 'Quiet opening lands.');
  });

  test('leaves other lines alone', () {
    expect(withoutLeadingTitle('Fuzed into one plot.', 'Fuze'), 'Fuzed into one plot.');
    expect(withoutLeadingTitle('Nine episodes are waiting.', 'Avatar'), 'Nine episodes are waiting.');
    expect(withoutLeadingTitle('Fuze', 'Fuze'), 'Fuze');
  });
}
