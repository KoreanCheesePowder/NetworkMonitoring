C.P Wallpad Network Monitor v1.0.0
제작자: 치즈가루

기능
- TCP 포트 연결 확인으로 네트워크 장비 상태 감시
- 기본 대상
  1) 월패드 제어 192.168.1.100:8899
  2) 현관문/BLE 192.168.1.101:8900
  3) WAN 로거 192.168.1.102:22
- 대상 1~8까지 설정에서 IP / 이름 / TCP 포트를 자유롭게 변경 가능
- [대상 n] 사용 = ON : 추가/감시
- [대상 n] 사용 = OFF : 삭제/미사용
- 기본 10초 주기, 2초 연결 제한, 연속 3회 실패 시 비정상
- 한 번 성공하면 즉시 정상 복귀
- 루틴 조건에서 전체 상태 및 대상 1~8 상태를 각각 선택 가능

설치
1. ZIP을 새 폴더에 압축 해제
2. SETUP-AND-INSTALL.cmd 실행
3. SmartThings 앱 -> 기기 추가 -> 주변 검색
4. "월패드 네트워크 상태" 기기 설정에서 대상 편집

권장 루틴
IF 대상 1 상태 = 비정상 THEN 알림
IF 대상 2 상태 = 비정상 THEN 알림
IF 대상 3 상태 = 비정상 THEN 알림

주의
- ICMP Ping이 아니라 TCP 서비스 포트 연결 여부를 검사합니다.
- 장비에서 항상 열려 있는 포트를 지정해야 합니다.
- 대상 4~8은 기본 미사용이며 설정에서 켜면 추가할 수 있습니다.


v1.0.6
- Preference apply debounce added.
- Changed IP/port/name are re-read after save and workers restart with final values.
- Target 2 default TCP port changed to 8899.
