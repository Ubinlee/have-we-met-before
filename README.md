# Have We Met Before?

사진의 촬영 시각과 대략적인 위치 메타데이터를 비교해, 두 사람이 서로 알기 전에 가까이 있었던 순간을 찾는 iOS 앱입니다.

## Development environment

- Interface: SwiftUI
- Language: Swift
- Deployment target: iOS 18.0
- Supported device: iPhone
- Orientation: Portrait

## Privacy principles

- 사진 원본과 썸네일을 서버에 업로드하지 않습니다.
- 촬영 시각과 위치 메타데이터는 기기에서 추출합니다.
- 서버에는 매칭에 필요한 최소한의 가공 데이터만 전송합니다.
- 실제 사진, 정확한 좌표, 닉네임, 초대 코드를 저장소나 로그에 올리지 않습니다.

## Collaboration

- `main`에 직접 커밋하지 않습니다.
- 작업 브랜치에서 변경하고 Pull Request로 병합합니다.
- 최소 한 명의 리뷰를 받은 뒤 병합합니다.

## Local setup

1. 저장소를 Clone합니다.
2. `HaveWeMetBefore.xcodeproj`를 엽니다.
3. 자신의 Apple Developer Team을 선택합니다.
4. iPhone Simulator에서 앱을 실행합니다.

> Bundle Identifier는 Apple Developer 및 App Store Connect 설정 전에 팀 값으로 변경해야 합니다.
