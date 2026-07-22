import EditorCore
import Metal
import MetalRenderer
import PatternEngine
import SwiftUI

#if os(macOS)
let editorControlExtent: CGFloat = 32
let editorInspectorWidth: CGFloat = 216
#else
let editorControlExtent: CGFloat = 44
let editorInspectorWidth: CGFloat = 252
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    private let state: CanvasState
    @State private var runtimeError: MetalRendererError?
    @State private var pointerCancellationGeneration: UInt = 0
    @FocusState private var editorFocused: Bool
    #if DEBUG && os(macOS)
    @State private var debugHUDVisible = false
    @State private var debugPerformanceMonitor = DebugPerformanceMonitor()
    #endif

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            state = .unavailable("Pattern requires a Metal-capable Apple device.")
            return
        }

        do {
            let configuration = try TilingCanvasConfiguration(
                pixelSize: GridCanvasContract.defaultPixelSize,
                tiling: .grid
            )
            let renderer = try GridRenderer(
                device: device,
                drawableSize: PatternSize(width: 1, height: 1),
                configuration: configuration
            )
            state = .ready(
                EditorSessionController(renderer: renderer)
            )
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    var body: some View {
        Group {
            switch state {
            case let .ready(controller):
                editorShell(controller)
            case let .unavailable(message):
                ContentUnavailableView(
                    "Renderer Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editorShell(
        _ controller: EditorSessionController
    ) -> some View {
        VStack(spacing: 0) {
            EditorTopBar(
                controller: controller,
                requestEditorFocus: requestEditorFocus
            )
            Divider()
            HStack(spacing: 0) {
                ToolRail(
                    controller: controller,
                    requestEditorFocus: requestEditorFocus
                )
                Divider()
                ZStack(alignment: .topLeading) {
                    MetalCanvas(
                        controller: controller,
                        renderer: controller.renderer,
                        brushDiameter: controller.model.brushDiameter,
                        requestEditorFocus: requestEditorFocus,
                        pointerCancellationGeneration:
                            pointerCancellationGeneration
                    )
                    #if DEBUG && os(macOS)
                    if debugHUDVisible {
                        DebugPerformanceHUD(
                            snapshot: debugPerformanceMonitor.snapshot
                        )
                        .padding(12)
                        .allowsHitTesting(false)
                    }
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                TilingInspector(
                    controller: controller,
                    runtimeError: $runtimeError,
                    requestEditorFocus: requestEditorFocus
                )
            }
        }
        .overlay(alignment: .top) {
            if let runtimeError {
                ErrorBanner(error: runtimeError) {
                    self.runtimeError = nil
                    requestEditorFocus()
                }
                .padding(.top, editorControlExtent + 16)
            }
        }
        .focusable()
        .focused($editorFocused)
        .onChange(of: editorFocused) { _, isFocused in
            if !isFocused {
                cancelCurrentInteraction(controller)
            }
        }
        .onKeyPress(phases: .all) { press in
            handleKeyPress(press, controller: controller)
        }
        .onAppear {
            requestEditorFocus()
            controller.onError = {
                runtimeError = $0
            }
            controller.renderer.onError = {
                runtimeError = $0
            }
            #if DEBUG && os(macOS)
            let monitor = debugPerformanceMonitor
            controller.renderer.onInteractiveFramePresented = { timestamp, targetFramesPerSecond in
                monitor.recordPresentedFrame(
                    at: timestamp,
                    targetFramesPerSecond: targetFramesPerSecond
                )
            }
            #endif
        }
        .onDisappear {
            cancelCurrentInteraction(controller)
            controller.onError = nil
            controller.renderer.onError = nil
            #if DEBUG && os(macOS)
            controller.renderer.onInteractiveFramePresented = nil
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                cancelCurrentInteraction(controller)
            }
        }
        #if os(macOS)
        .onChange(of: controlActiveState) { _, activeState in
            if activeState != .key {
                cancelCurrentInteraction(controller)
            }
        }
        .focusedSceneValue(
            \.editorCommandActions,
            commandActions(for: controller)
        )
        #endif
    }

    private func requestEditorFocus() {
        editorFocused = true
    }

    private func cancelCurrentInteraction(
        _ controller: EditorSessionController
    ) {
        handleEditorShortcut(
            .cancel,
            controller: controller,
            pointerCancellationGeneration: &pointerCancellationGeneration
        )
    }

    private func handleKeyPress(
        _ press: KeyPress,
        controller: EditorSessionController
    ) -> KeyPress.Result {
        guard editorFocused else {
            return .ignored
        }

        #if DEBUG && os(macOS)
        if press.phase == .down, press.characters == "~" {
            debugHUDVisible.toggle()
            if debugHUDVisible {
                debugPerformanceMonitor.reset()
            }
            return .handled
        }
        #endif

        guard let phase = editorPhase(from: press.phase),
              let shortcut = EditorKeymap.resolve(
                editorKey(from: press),
                modifiers: editorModifiers(from: press.modifiers),
                phase: phase
              )
        else {
            return .ignored
        }

        handleEditorShortcut(
            shortcut,
            controller: controller,
            pointerCancellationGeneration: &pointerCancellationGeneration
        )
        return .handled
    }

    private func editorKey(from press: KeyPress) -> EditorKey {
        switch press.key {
        case .escape:
            .escape
        case .space:
            .space
        case .return:
            .returnKey
        default:
            EditorKey(rawValue: press.characters)
        }
    }

    private func editorPhase(from phase: KeyPress.Phases) -> EditorKeyPhase? {
        switch phase {
        case .down:
            .down
        case .repeat:
            .repeat
        case .up:
            .up
        default:
            nil
        }
    }

    private func editorModifiers(
        from modifiers: EventModifiers
    ) -> EditorKeyModifiers {
        var result: EditorKeyModifiers = []
        if modifiers.contains(.command) {
            result.insert(.command)
        }
        if modifiers.contains(.shift) {
            result.insert(.shift)
        }
        if modifiers.contains(.option) {
            result.insert(.option)
        }
        if modifiers.contains(.control) {
            result.insert(.control)
        }
        return result
    }

    #if os(macOS)
    private func commandActions(
        for controller: EditorSessionController
    ) -> EditorCommandActions {
        EditorCommandActions(
            undo: {
                controller.undo()
                requestEditorFocus()
            },
            redo: {
                controller.redo()
                requestEditorFocus()
            },
            clear: {
                controller.clear()
                requestEditorFocus()
            },
            selectDraw: {
                controller.handleTool(.draw)
                requestEditorFocus()
            },
            selectErase: {
                controller.handleTool(.erase)
                requestEditorFocus()
            },
            canUndo: controller.model.canUndo,
            canRedo: controller.model.canRedo,
            canEdit: !controller.model.isBusy
        )
    }
    #endif

    private enum CanvasState {
        case ready(EditorSessionController)
        case unavailable(String)
    }
}

private struct ErrorBanner: View {
    let error: MetalRendererError
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error.localizedDescription)
                .font(.caption)
                .lineLimit(2)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Error")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: editorControlExtent)
        .foregroundStyle(.white)
        .background(Color.red.opacity(0.92))
    }
}
