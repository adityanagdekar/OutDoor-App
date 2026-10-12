import Foundation

struct Challenge: Identifiable, Hashable {
    let id: String
    let title: String
    let instruction: String
    let systemImage: String

    static let samples = [
        Challenge(
            id: "tree",
            title: "A Tree",
            instruction: "Take a clear photo of a tree.",
            systemImage: "tree"
        ),
        Challenge(
            id: "flower",
            title: "A Flower",
            instruction: "Take a clear photo of a flower.",
            systemImage: "camera.macro"
        ),
        Challenge(
            id: "cloud",
            title: "A Cloud",
            instruction: "Take a clear photo of a cloud.",
            systemImage: "cloud"
        )
    ]
}
