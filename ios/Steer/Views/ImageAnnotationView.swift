import PencilKit
import SwiftUI
import UIKit

struct ImageAnnotationSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ImageAnnotationView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case pen
        case highlighter
        case eraser

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .eraser: "eraser"
            }
        }
    }

    let image: UIImage
    let onSave: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()
    @State private var tool = Tool.pen
    @State private var color = UIColor.systemRed
    @State private var canvasSize = CGSize.zero

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let size = fittedSize(image: image.size, inside: proxy.size)
                ZStack {
                    Color.black
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                        PencilAnnotationCanvas(drawing: $drawing, tool: tool, color: color)
                    }
                    .frame(width: size.width, height: size.height)
                    .onAppear { canvasSize = size }
                    .onChange(of: size) { _, value in canvasSize = value }
                }
            }
            .safeAreaInset(edge: .bottom) {
                annotationToolbar
            }
            .navigationTitle("Annotate Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Image") {
                        onSave(renderedImage())
                        dismiss()
                    }
                }
            }
        }
    }

    private var annotationToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Tool.allCases) { candidate in
                    Button(candidate.rawValue.capitalized, systemImage: candidate.systemImage) {
                        tool = candidate
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .background(tool == candidate ? Theme.ink : Color(uiColor: .tertiarySystemFill))
                    .foregroundStyle(tool == candidate ? .white : .primary)
                    .clipShape(Circle())
                }

                Divider()
                    .frame(height: 28)

                ForEach(AnnotationColor.all) { candidate in
                    Button { color = candidate.color } label: {
                        Circle()
                            .fill(Color(uiColor: candidate.color))
                            .frame(width: 28, height: 28)
                            .overlay {
                                Circle()
                                    .stroke(
                                        color == candidate.color ? Theme.ink : Color.white.opacity(0.65),
                                        lineWidth: color == candidate.color ? 3 : 1
                                    )
                            }
                    }
                    .accessibilityLabel(candidate.name)
                    .disabled(tool == .eraser)
                }

                Divider()
                    .frame(height: 28)

                Button("Undo", systemImage: "arrow.uturn.backward") {
                    var strokes = drawing.strokes
                    if !strokes.isEmpty {
                        strokes.removeLast()
                        drawing = PKDrawing(strokes: strokes)
                    }
                }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .disabled(drawing.strokes.isEmpty)

                Button("Clear", systemImage: "trash", role: .destructive) {
                    drawing = PKDrawing()
                }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .disabled(drawing.strokes.isEmpty)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func fittedSize(image: CGSize, inside bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func renderedImage() -> UIImage {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let scale = image.size.width / canvasSize.width
            let overlay = drawing.image(
                from: CGRect(origin: .zero, size: canvasSize),
                scale: scale
            )
            overlay.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

private struct PencilAnnotationCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let tool: ImageAnnotationView.Tool
    let color: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context _: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
        switch tool {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: color, width: 4)
        case .highlighter:
            canvas.tool = PKInkingTool(.marker, color: color.withAlphaComponent(0.45), width: 14)
        case .eraser:
            canvas.tool = PKEraserTool(.vector)
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private var drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}

private struct AnnotationColor: Identifiable {
    let name: String
    let color: UIColor

    var id: String { name }

    static let all = [
        AnnotationColor(name: "Red", color: .systemRed),
        AnnotationColor(name: "Yellow", color: .systemYellow),
        AnnotationColor(name: "Blue", color: .systemBlue),
        AnnotationColor(name: "White", color: .white),
    ]
}
