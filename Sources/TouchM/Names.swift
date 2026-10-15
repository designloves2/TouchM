import Foundation

/// Display names for stored gesture / action / context identifiers. Stored values stay English.
enum Names {
    static let korean = Bundle.main.preferredLocalizations.first == "ko"
    private static let actions: [String: String] = [
        "click": "클릭", "click and drag": "클릭 후 드래그", "scroll": "스크롤", "move cursor": "커서 이동",
        "mission control": "미션 컨트롤", "show app windows": "앱 윈도우 보기", "swipe between spaces": "스페이스 전환",
        "desktop launchpad": "데스크탑 / 런치패드", "notification center": "알림 센터", "look up in dictionary": "사전에서 찾기",
        "show hide dock": "Dock 표시/숨김", "keyboard viewer": "화상 키보드 (키보드 뷰어)", "adjust magnification": "확대/축소 조정", "rotate": "회전", "keystroke": "키 입력",
        "open app": "앱 열기", "open url": "URL 열기", "run shell command": "셸 명령 실행", "run applescript": "AppleScript 실행", "none": "없음",
        "show hide magnifier": "확대경 표시/숨김", "move magnifier": "확대경 이동",
    ]
    private static let contexts: [String: String] = [
        "Anywhere": "어디서든", "Scrollable areas": "스크롤 영역", "Web content": "웹 콘텐츠", "Menu bar": "메뉴 막대",
        "Menu items": "메뉴 항목", "Window title bars": "창 제목 막대", "File dialogs": "파일 대화상자", "Buttons": "버튼",
        "Text fields": "텍스트 필드", "Lists / tables": "목록 / 표", "Toolbars": "도구 막대",
    ]
    private static let words: [(String, String)] = [
        ("one finger", "한 손가락"), ("two finger", "두 손가락"), ("three finger", "세 손가락"), ("four finger", "네 손가락"), ("five finger", "다섯 손가락"),
        ("press and tap", "누른 채 탭"), ("from edge", "가장자리에서"),
        ("swipe horizontal", "스와이프 수평"), ("swipe vertical", "스와이프 수직"),
        ("swipe left", "스와이프 왼쪽"), ("swipe right", "스와이프 오른쪽"), ("swipe up", "스와이프 위"), ("swipe down", "스와이프 아래"),
        ("swipe", "스와이프"), ("pinch expand", "핀치 확대"), ("pinch contract", "핀치 축소"), ("pinch", "핀치"),
        ("tap", "탭"), ("press", "길게 누르기"), ("drag", "드래그"), ("rotate", "회전"),
        ("left", "왼쪽"), ("right", "오른쪽"), ("up", "위"), ("down", "아래"),
    ]
    /// Gesture identifier → display text.
    static func gesture(_ g: String) -> String {
        guard korean else { return g }
        var s = g
        for (e, k) in words { s = s.replacingOccurrences(of: e, with: k) }
        // "한 손가락 스와이프 왼쪽 가장자리에서" reads better with the edge first
        if s.hasSuffix(" 가장자리에서") { s = "가장자리에서 " + s.dropLast(" 가장자리에서".count) }
        return s
    }
    static func action(_ a: String) -> String { korean ? (actions[a] ?? a) : a }
    static func context(_ c: String) -> String { korean ? (contexts[c] ?? c) : c }
}
