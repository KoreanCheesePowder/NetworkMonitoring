C.P Wallpad Network Monitor v1.1.2
제작자: 치즈가루

기능
- TCP 포트 연결 확인으로 네트워크 장비 상태 감시
- 기본 대상
  1) 월패드 제어 192.168.1.100:8899
  2) 현관문/BLE 192.168.1.101:8898 (전용 Health)
  3) WAN 로거 192.168.1.102:22
- 대상 1~8까지 설정에서 IP / 이름 / TCP 포트를 자유롭게 변경 가능
- [대상 n] 사용 = ON : 추가/감시
- [대상 n] 사용 = OFF : 삭제/미사용
- 기본 10초 주기, 2초 연결 제한, 연속 3회 실패 시 비정상
- 비정상 후 정상 복귀도 설정된 연속 성공 횟수를 만족해야 복귀
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
- 당시 Target 2 기본 TCP 포트를 8899로 사용했으나 v1.1.0부터 8898 Health 포트로 분리.


v1.1.0
- IP101 모니터링을 RS485 브리지 8899에서 전용 Health 포트 8898로 분리.
- 기존 설치에서 IP101:8899 설정은 내부적으로 8898로 호환 전환.
- 상태가 바뀌지 않을 때 Summary/제작자 이벤트 반복 발행 제거.
- 수동 새로고침/설정 저장 시 불필요한 checking -> online 상태 튐 제거.
- 루틴용 status 이벤트는 실제 상태 변경에만 state_change=true로 발행.


v1.1.1
- IP101이 어느 대상 슬롯에 있더라도 192.168.1.101:8899 설정은 8898 Health 포트로 자동 호환 전환.
- 기본/기존 루틴 capability와 상태 변경 이벤트 구조 유지.


v1.1.2
- IP101 Stable 펌웨어의 전용 Health 8898과 조합하도록 유지.
- IP99 Stable 펌웨어 8899의 짧은 TCP probe 방식과 호환.
- OTA/웹 업데이트 기능과 무관하게 네트워크 상태만 감시.
- 기존 루틴 capability, 실패/복귀 연속 횟수, 이벤트 구조 유지.
