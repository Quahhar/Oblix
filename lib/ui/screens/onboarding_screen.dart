import 'package:flutter/material.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../theme/oblix_theme.dart';
import 'login_screen.dart';

/// First-run walkthrough: the card fan, what capture will cover, and Ask.
/// Shown once per install (flag in the meta table), then never again.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  static const _seenKey = 'onboarding_seen';

  static Future<bool> hasSeen() async =>
      (await MetaDao(AppDatabase.instance).getSetting(_seenKey)) == '1';

  static Future<void> markSeen() =>
      MetaDao(AppDatabase.instance).setSetting(_seenKey, '1');

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish({bool register = false}) async {
    await OnboardingScreen.markSeen();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => LoginScreen(startInRegisterMode: register),
      ),
    );
  }

  void _next() {
    if (_page == 2) {
      _finish(register: true);
    } else {
      _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 44,
              child: _page == 0
                  ? null
                  : Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 24),
                        child: GestureDetector(
                          onTap: () => _finish(),
                          child: Text(
                            'Skip',
                            style: OblixType.ui(c,
                                size: 13.5,
                                weight: FontWeight.w500,
                                color: c.inkMuted),
                          ),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: const [
                  _WelcomePage(),
                  _CapturePage(),
                  _AskPage(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < 3; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          margin: const EdgeInsets.symmetric(horizontal: 3.5),
                          width: i == _page ? 22 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: i == _page ? c.accent : c.outline,
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: Material(
                      color: c.accent,
                      shape: const StadiumBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _next,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Center(
                            child: Text(
                              _page == 2 ? 'Get started' : 'Continue',
                              style: OblixType.ui(c,
                                  size: 16,
                                  weight: FontWeight.w600,
                                  color: c.onAccent),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => _finish(),
                    child: Text(
                      'I already have an account',
                      style: OblixType.ui(c,
                          size: 14,
                          weight: FontWeight.w500,
                          color: c.inkSecondary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Page 1: a fan of three note cards under the wordmark.
class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 34),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 216,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                Transform.translate(
                  offset: const Offset(-62, 10),
                  child: Transform.rotate(
                    angle: -0.157,
                    child: _FanCard(lines: const [0.7, 0.55, 0.75]),
                  ),
                ),
                Transform.translate(
                  offset: const Offset(62, 14),
                  child: Transform.rotate(
                    angle: 0.157,
                    child: _FanCard(lines: const [0.55, 0.8, 0.65]),
                  ),
                ),
                _FanCard(
                  elevated: true,
                  title: 'Tokyo, day 3',
                  lines: const [1, 0.85, 0.7],
                  tag: 'travel',
                ),
              ],
            ),
          ),
          const SizedBox(height: 44),
          Text.rich(
            TextSpan(
              text: 'Oblix',
              style: TextStyle(
                fontFamily: OblixType.serif,
                fontSize: 46,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.9,
                color: c.ink,
              ),
              children: [TextSpan(text: '.', style: TextStyle(color: c.accent))],
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 250),
            child: Text(
              'One calm place for everything you note.',
              textAlign: TextAlign.center,
              style: OblixType.ui(c, size: 15.5, color: c.inkSecondary)
                  .copyWith(height: 1.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _FanCard extends StatelessWidget {
  final bool elevated;
  final String? title;
  final List<double> lines;
  final String? tag;

  const _FanCard({
    this.elevated = false,
    this.title,
    required this.lines,
    this.tag,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Container(
      width: elevated ? 152 : 148,
      height: elevated ? 196 : 186,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.hairline),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: c.ink.withValues(alpha: elevated ? 0.14 : 0.08),
            blurRadius: elevated ? 34 : 24,
            offset: Offset(0, elevated ? 16 : 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Text(
              title!,
              style: TextStyle(
                fontFamily: OblixType.serif,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: c.ink,
              ),
            )
          else
            Container(
              height: 7,
              width: 84,
              decoration: BoxDecoration(
                color: c.chip,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          const SizedBox(height: 10),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FractionallySizedBox(
                widthFactor: line,
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          if (tag != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tag!,
                style: OblixType.ui(c,
                    size: 10.5, weight: FontWeight.w600, color: c.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Page 2: what the one button will cover. Audio/Scan/Sketch are labelled
/// "soon" — they're designed but not built yet, and onboarding shouldn't
/// promise what the app can't do today.
class _CapturePage extends StatelessWidget {
  const _CapturePage();

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    const items = [
      (Icons.description_outlined, 'Note', null),
      (Icons.check_circle_outline, 'Task', null),
      (Icons.mic_none, 'Audio', 'soon'),
      (Icons.crop_free, 'Scan', 'soon'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Capture anything.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: OblixType.serif,
              fontSize: 31,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.45,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text(
              'Notes and tasks today; voice, scans and clippings are on the '
              'way — one button, zero ceremony.',
              textAlign: TextAlign.center,
              style: OblixType.ui(c, size: 14.5, color: c.inkSecondary)
                  .copyWith(height: 1.55),
            ),
          ),
          const SizedBox(height: 30),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 11,
            crossAxisSpacing: 11,
            childAspectRatio: 2.1,
            children: [
              for (final (icon, label, badge) in items)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: c.surface,
                    border: Border.all(color: c.hairline),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 21, color: c.accent),
                      const SizedBox(height: 9),
                      Row(
                        children: [
                          Text(label,
                              style: OblixType.ui(c,
                                  size: 13.5, weight: FontWeight.w600)),
                          if (badge != null) ...[
                            const SizedBox(width: 5),
                            Text(badge,
                                style: OblixType.ui(c,
                                    size: 13.5,
                                    weight: FontWeight.w500,
                                    color: c.inkMuted)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration:
                      BoxDecoration(color: c.accent, shape: BoxShape.circle),
                  child: Icon(Icons.add, size: 14, color: c.onAccent),
                ),
                const SizedBox(width: 9),
                Text(
                  'All of it lives behind the one button',
                  style: OblixType.ui(c,
                      size: 12.5, weight: FontWeight.w500, color: c.accentDeep),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Page 3: search across everything.
class _AskPage extends StatelessWidget {
  const _AskPage();

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Find it instantly.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: OblixType.serif,
              fontSize: 31,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.45,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text(
              'Full-text search runs on your device, so it works on a plane, '
              'in a tunnel, anywhere.',
              textAlign: TextAlign.center,
              style: OblixType.ui(c, size: 14.5, color: c.inkSecondary)
                  .copyWith(height: 1.55),
            ),
          ),
          const SizedBox(height: 30),
          Container(
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.accent, width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: c.accent.withValues(alpha: 0.1),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 16, color: c.accent),
                const SizedBox(width: 10),
                Text('pricing decision',
                    style: OblixType.ui(c, size: 14.5)),
                Container(
                  width: 2,
                  height: 16,
                  margin: const EdgeInsets.only(left: 1),
                  color: c.accent,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.hairline),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 11, color: c.accent),
                    const SizedBox(width: 6),
                    Text('FROM YOUR NOTES',
                        style: OblixType.eyebrow(c, color: c.accent)),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Q3 planning draft — keep the single tier until churn '
                  'passes 4%.',
                  style: OblixType.noteBody(c),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
