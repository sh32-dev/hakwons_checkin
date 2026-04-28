import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'firebase_options.dart';
import 'models/academy_session.dart';
import 'screens/checkin_screen.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 오프라인 환경에서도 폰트가 동작하도록 런타임 패칭 비활성화
  GoogleFonts.config.allowRuntimeFetching = false;

  // 한국어 날짜 형식 초기화
  await initializeDateFormatting('ko');

  // 가로 모드 고정
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // 상태바 / 네비게이션바 숨김 (키오스크 전용)
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(const HagwonsCheckinApp());
}

class HagwonsCheckinApp extends StatelessWidget {
  const HagwonsCheckinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '학원쓰 출결',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3D5AFE),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      routes: {
        '/login': (_) => const LoginScreen(),
      },
      home: const _InitRouter(),
    );
  }
}

// 저장된 세션 유무에 따라 화면을 분기하는 라우터
class _InitRouter extends StatelessWidget {
  const _InitRouter();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AcademySession?>(
      future: AuthService.getSavedSession(),
      builder: (context, snapshot) {
        // 로딩 중
        if (snapshot.connectionState != ConnectionState.done) {
          return const _SplashScreen();
        }

        // 저장된 세션이 있으면 바로 출결 화면으로
        final session = snapshot.data;
        if (session != null) {
          return CheckinScreen(session: session);
        }

        // 없으면 로그인 화면으로
        return const LoginScreen();
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0D1117),
      body: Center(
        child: CircularProgressIndicator(color: Colors.blueAccent, strokeWidth: 2),
      ),
    );
  }
}
