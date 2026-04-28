# 학원쓰 출결 앱 개발 진행 현황

## 프로젝트 기본 정보
- **앱 이름**: 학원쓰 출결 (hagwons_checkin)
- **플랫폼**: Android 전용 (키오스크 — 아트론 미니 단말기)
- **방향**: 가로 모드(Landscape) 고정
- **Firebase 프로젝트**: hakwons (기존 학원쓰 앱과 공유)
- **패키지명**: com.hagwons.hagwons_checkin

---

## 완성된 기능

### 1. Firebase 연결
- `flutterfire configure --project=hakwons` 완료
- `google-services.json`, `firebase_options.dart` 생성됨
- `android/app/src/main/AndroidManifest.xml`에 INTERNET + NFC 권한 추가

### 2. 로그인 화면 (`lib/screens/login_screen.dart`)
- **레이아웃**: 5:5 좌우 분할
- **좌측 50%**: 라벤더/핑크/블루 Blob 배경 (CustomPainter + ImageFilter.blur) + 흰 박스 안 "학원쓰 출결" (Noto Sans KR Light) + NFC 아이콘
- **우측 50%**: 흰 배경, "Hakwons Check In" (Pacifico + 라벤더 그라디언트), 전화번호 입력 폼
- **OTP 2단계 인증**: Firebase Phone Auth
- **테스트 모드**: `01011111111` 입력 시 네트워크 없이 바로 OTP 단계 진입 (코드: `123456`)
- **자동 로그인**: SharedPreferences에 세션 저장

### 3. 출결 대기 화면 (`lib/screens/checkin_screen.dart`)
- **레이아웃**: 7:3 좌우 분할
- **좌측 70%**: #4E54C8→#8F94FB(또는 Blob) 배경 + "카드를 리더기에 대주세요" (w800, 흰색)
- **우측 30%**: #F8F9FA 크림 배경 + "Hakwons check in" 로고 + 실시간 출결 리스트 (StreamBuilder)
- **피드백 오버레이**: AnimationController 기반 FadeTransition + ScaleTransition (3초 표시)
  - 등원: 초록 카드 "OOO 학생 등원 완료"
  - 하원: 주황 카드 "OOO 학생 하원 완료"
  - 중복: 노랑 카드 "이미 기록되었습니다."
  - 오류/미등록: 빨강 카드

### 4. NFC 태깅 로직 (`lib/services/attendance_service.dart`)
- `nfc_manager` + `platform_tags` 사용
- NFC UID → `students` 컬렉션 조회 (academyId + nfcUid 복합 쿼리)
- 출결 토글: 오늘 첫 태깅 → 등원 / 이후 → 등원↔하원 반전
- **20분 중복 방지**: 마지막 기록 후 20분 이내 재태깅 무시

### 5. 데이터 구조 (Firestore)
```
students/{id}
  - academyId: String
  - name: String
  - nfcUid: String  ← 대문자 HEX (예: "AABBCCDD")
  - grade: String?

attendance/{id}
  - academyId: String
  - studentId: String
  - studentName: String
  - type: "arrival" | "departure"
  - timestamp: Timestamp
  - date: String  ← "yyyy-MM-dd"
```

---

## 파일 구조
```
lib/
  main.dart                      ← Firebase init, 세션 분기 라우터
  firebase_options.dart          ← FlutterFire CLI 생성
  models/
    academy_session.dart         ← 로그인 세션 데이터
    student.dart                 ← 학생 모델
    attendance_record.dart       ← 출결 기록 모델
  services/
    auth_service.dart            ← Phone OTP 로그인 + 테스트 모드
    attendance_service.dart      ← NFC 태깅 → 출결 처리 로직
  screens/
    login_screen.dart            ← OTP 로그인 화면
    checkin_screen.dart          ← 출결 대기 + 피드백 화면

assets/
  fonts/
    NotoSansKR-Light.ttf
    NotoSansKR-Regular.ttf
    NotoSansKR-Bold.ttf
    Pacifico-Regular.ttf
```

---

## 주요 패키지
| 패키지 | 버전 | 용도 |
|---|---|---|
| nfc_manager | ^3.5.0 | NFC 태깅 감지 |
| firebase_core | ^3.13.0 | Firebase 초기화 |
| firebase_auth | ^5.3.0 | Phone OTP 인증 |
| cloud_firestore | ^5.6.6 | 학생/출결 데이터 |
| shared_preferences | ^2.3.0 | 자동 로그인 세션 저장 |
| google_fonts | ^6.2.1 | (설치됨, 로컬 폰트로 대체) |
| intl | ^0.20.2 | 날짜 포맷 (한국어) |

---

## 내일 해야 할 것
- [ ] 에뮬레이터 화면 렌더링 문제 해결 (또는 실기기 연결 테스트)
- [ ] Firebase Authentication에서 Phone 로그인 활성화 확인
- [ ] Firebase Firestore 복합 인덱스 생성 (academyId + nfcUid on students, academyId + date + timestamp on attendance)
- [ ] Firestore에 테스트 학생 데이터 등록 (nfcUid 포함)
- [ ] 실기기 NFC 태깅 테스트
- [ ] academies 컬렉션 구조 확인 및 학원 정보 연동

---

## 에뮬레이터 이슈 (참고)
에뮬레이터(Android 15, API 35)에서 Google 서버(googleapis.com, firestore.googleapis.com) DNS 해석 실패로 Firebase 연결 불가. 코드 문제 아님 — 실기기에서는 정상 동작. NFC도 에뮬레이터 미지원이므로 실기기 테스트 필수.
