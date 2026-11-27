# 부평역 B1 드럼・음악연습실 예약 시스템

24시간 B1 음악 연습실을 온라인으로 예약하는 화면입니다(v1.0.0 정식 오픈, 2026-11-27).

## 주소

- 손님 예약 화면: https://room.hyunmusic.com/
- 관리자 화면: https://room.hyunmusic.com/#admin
- 학원 로비 PC 화면: https://room.hyunmusic.com/academy/
- 가격표만 보기: https://room.hyunmusic.com/price/

## 구성

- 화면: `index.html` 한 파일입니다(GitHub Pages로 배포하며, `main`에 올리면 반영됩니다).
- 서버: Supabase(DB 함수·제약·RLS가 예약 규칙을 최종 결정)입니다. 변경 내용은 `supabase/migrations/`에 번호 순서로 있습니다.
- 제휴회원 명부: 구글 시트 Apps Script(`google-apps-script/roster_sync.gs`)가 1시간마다 반영합니다.
- 새 버전 확인: 켜 둔 화면이 `version.json`을 보고 스스로 새로 고칩니다(배포할 때마다 `index.html`의 `APP_VERSION`과 같게 올립니다).

## 주의

- 비밀 키(`service_role`, `.env`)와 출입 비밀번호는 저장소에 넣지 않습니다. 화면에는 공개용(Publishable) 키만 들어 있습니다.
- 작업 지침은 `CLAUDE.md`, 지난 기록은 `HISTORY.md`에 있습니다.
