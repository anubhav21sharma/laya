#if DEBUG
import BrushConverter
import BrushFormat
import EditorCore
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
@testable import ProfessionalBrushEvidenceValidation
import Testing

@Suite("Brush Lab session", .serialized)
@MainActor
struct BrushLabSessionTests {
    @Test
    func professionalManualCardMatrixCoversEveryRequiredStageFiveReview() {
        let cards = BrushLabManualCard.professionalFixedMatrix
        let professionalIDs = Set(
            ProfessionalBrushCatalog.all.map(\.id.rawValue)
        )

        #expect(cards.map(\.cardID) == cards.map(\.cardID).sorted())
        #expect(Set(cards.map(\.brushID)) == professionalIDs)
        #expect(cards.allSatisfy {
            $0.passes.first?.role == .professionalDraw
        })

        for brushID in professionalIDs {
            let brushCards = cards.filter { $0.brushID == brushID }
            let expectedGestures: Set<BrushLabManualGesture> = [
                .tap,
                .slowLine,
                .fastLine,
                .pressureRamp,
                .tiltSweep,
                .curve,
                .sharpCorner,
                .crossHatch,
                .repeatedBuildup,
                .periodicSeamCrossing,
                .radialRotation,
                .radialReflection,
                .eraserRetrace,
                .mouseFallback,
                .tabletInput,
            ]
            #expect(expectedGestures.isSubset(of: Set(brushCards.map(\.gesture))))
            let tapDiameters = Set(
                brushCards.filter { $0.gesture == .tap }
                    .map(\.nominalDiameter)
            )
            #expect(tapDiameters == [2, 20, 2_000])
        }
    }

    @Test
    func professionalCardCanBeSelectedThroughProductionReviewPath()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(
            runtime.session.professionalManualCards.first {
                $0.brushID
                    == ProfessionalBrushCatalog.graphitePencil.id.rawValue
                    && $0.gesture == .slowLine
            }
        )

        runtime.session.selectReviewMatrix(.stageFiveProfessional)
        try await runtime.session.selectReviewCard(card.cardID)
        let replay = try await runtime.session.replaySelectedReviewCard()

        #expect(runtime.session.selectedReviewCardID == card.cardID)
        #expect(
            runtime.session.package?.definition.id
                == ProfessionalBrushCatalog.graphitePencil.id
        )
        #expect(
            runtime.controller.renderer.preparedBrush(for: .draw)?
                .renderIdentity.definitionID
                == ProfessionalBrushCatalog.graphitePencil.id
        )
        #expect(
            runtime.controller.renderer.preparedBrush(for: .erase)?
                .renderIdentity.definitionID
                == EditorBrushCatalog.eraser.id
        )
        #expect(replay.professionalPasses.count == card.passes.count)
        #expect(replay.professionalPasses[0].role == .professionalDraw)
        #expect(
            runtime.session.activeProfessionalCompiledBrush?
                .renderIdentity.definitionID
                == ProfessionalBrushCatalog.graphitePencil.id
        )
    }

    @Test
    func professionalPressureTiltAndDeviceScenariosDriveNamedInputs()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        runtime.session.selectReviewMatrix(.stageFiveProfessional)
        let cards = BrushLabManualCard.professionalFixedMatrix.filter {
            $0.brushID
                == ProfessionalBrushCatalog.graphitePencil.id.rawValue
        }
        let pressureCard = try #require(cards.first {
            $0.gesture == .pressureRamp
        })
        try await runtime.session.selectReviewCard(pressureCard.cardID)
        let pressureReplay = try await runtime.session
            .replaySelectedReviewCard()
        let pressure = pressureReplay.input

        let tiltCard = try #require(cards.first {
            $0.gesture == .tiltSweep
        })
        try await runtime.session.selectReviewCard(tiltCard.cardID)
        let tiltReplay = try await runtime.session.replaySelectedReviewCard()
        let tilt = tiltReplay.input

        let mouseCard = try #require(cards.first {
            $0.gesture == .mouseFallback
        })
        try await runtime.session.selectReviewCard(mouseCard.cardID)
        let mouseReplay = try await runtime.session.replaySelectedReviewCard()
        let mouse = mouseReplay.input

        let tabletCard = try #require(cards.first {
            $0.gesture == .tabletInput
        })
        try await runtime.session.selectReviewCard(tabletCard.cardID)
        let tabletReplay = try await runtime.session
            .replaySelectedReviewCard()
        let tablet = tabletReplay.input
        let pressureTiltCapabilities: StrokeInputCapabilities = [
            .pressure, .altitude, .azimuth,
        ]

        #expect(Set(pressure.map(\.source)) == ["pencil"])
        #expect(pressure.first?.pressure == 0.1)
        #expect(pressure.last?.pressure == 1)
        #expect(zip(pressure, pressure.dropFirst()).allSatisfy {
            $0.0.pressure < $0.1.pressure
        })

        let altitudes = try tilt.map {
            try #require($0.altitude)
        }
        #expect(Set(tilt.map(\.source)) == ["pencil"])
        #expect(zip(altitudes, altitudes.dropFirst()).allSatisfy {
            $0.0 > $0.1
        })
        #expect(tilt.allSatisfy {
            $0.capabilities
                & pressureTiltCapabilities.rawValue
                == pressureTiltCapabilities.rawValue
                && $0.azimuth != nil
        })

        #expect(Set(mouse.map(\.source)) == ["mouse"])
        #expect(mouse.allSatisfy {
            $0.capabilities == 0
                && $0.altitude == nil
                && $0.azimuth == nil
                && $0.roll == nil
        })

        #expect(Set(tablet.map(\.source)) == ["tablet"])
        #expect(Set(tablet.map(\.pressure)).count > 1)
        #expect(Set(tablet.compactMap(\.altitude)).count > 1)
        #expect(tablet.allSatisfy {
            $0.capabilities
                & pressureTiltCapabilities.rawValue
                == pressureTiltCapabilities.rawValue
        })
    }

    @Test
    func professionalMultiStrokeAndEraserLabelsDescribeExecutableActions()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        runtime.session.selectReviewMatrix(.stageFiveProfessional)
        let cards = BrushLabManualCard.professionalFixedMatrix.filter {
            $0.brushID
                == ProfessionalBrushCatalog.technicalInk.id.rawValue
        }
        let crossHatch = try #require(cards.first {
            $0.gesture == .crossHatch
        })
        let buildup = try #require(cards.first {
            $0.gesture == .repeatedBuildup
        })
        let eraser = try #require(cards.first {
            $0.gesture == .eraserRetrace
        })

        try await runtime.session.selectReviewCard(crossHatch.cardID)
        let crossHatchReplay = try await runtime.session
            .replaySelectedReviewCard()
        #expect(crossHatchReplay.input.filter {
            $0.phase == "began"
        }.count == 4)
        #expect(crossHatchReplay.professionalPasses[0].strokeCount == 4)

        try await runtime.session.selectReviewCard(buildup.cardID)
        let buildupReplay = try await runtime.session.replaySelectedReviewCard()
        #expect(buildupReplay.input.filter {
            $0.phase == "began"
        }.count == 4)
        #expect(buildupReplay.professionalPasses[0].strokeCount == 4)

        #expect(eraser.passes.map(\.role) == [
            .professionalDraw,
            .retainedStageFourEraser,
        ])
        #expect(eraser.passes.map(\.tool) == [.draw, .erase])
        #expect(eraser.passes[0].brushID == eraser.brushID)
        #expect(
            eraser.passes[1].brushID
                == EditorBrushCatalog.eraser.id.rawValue
        )
        #expect(
            eraser.passes[0].strokes[0].samples.map {
                SIMD2($0.x, $0.y)
            }
                == eraser.passes[1].strokes[0].samples.map {
                    SIMD2($0.x, $0.y)
                }
        )

        try await runtime.session.selectReviewCard(eraser.cardID)
        #expect(runtime.session.nextProfessionalPass?.passIndex == 0)
        let draw = try await runtime.session.replayNextProfessionalPass()
        #expect(draw.role == .professionalDraw)
        #expect(
            runtime.session.activeProfessionalCompiledBrush?
                .renderIdentity.definitionID
                == ProfessionalBrushCatalog.technicalInk.id
        )
        #expect(runtime.session.currentProfessionalPass?.passIndex == 0)
        #expect(runtime.session.nextProfessionalPass?.passIndex == 1)

        let erase = try await runtime.session.replayNextProfessionalPass()
        #expect(erase.role == .retainedStageFourEraser)
        #expect(erase.definitionID == EditorBrushCatalog.eraser.id.rawValue)
        #expect(
            runtime.session.activeProfessionalCompiledBrush?
                .renderIdentity.definitionID
                == EditorBrushCatalog.eraser.id
        )
        #expect(runtime.session.currentProfessionalPass?.passIndex == 1)
        #expect(runtime.session.nextProfessionalPass == nil)
        #expect(
            runtime.session.completedReplay?.professionalPasses.map(\.role)
                == [
                    .professionalDraw,
                    .retainedStageFourEraser,
                ]
        )
        let drawInput = Array(
            runtime.session.inputRecords[draw.inputRange]
        ).map { SIMD2($0.x, $0.y) }
        let eraseInput = Array(
            runtime.session.inputRecords[erase.inputRange]
        ).map { SIMD2($0.x, $0.y) }
        #expect(drawInput == eraseInput)
    }

    @Test
    func professionalSelectionResetsPlainPeriodicAndRadialReviewDocuments()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        runtime.session.selectReviewMatrix(.stageFiveProfessional)
        let cards = runtime.session.professionalManualCards.filter {
            $0.brushID
                == ProfessionalBrushCatalog.technicalInk.id.rawValue
        }
        let plain = try #require(cards.first {
            $0.gesture == .slowLine
        })
        let periodic = try #require(cards.first {
            $0.gesture == .periodicSeamCrossing
        })
        let radial = try #require(cards.first {
            $0.gesture == .radialRotation
        })

        for card in [plain, periodic, radial] {
            try await runtime.session.selectReviewCard(card.cardID)
            #expect(
                runtime.controller.renderer.documentConfiguration
                    == card.documentConfiguration
            )
            #expect(
                runtime.controller.model.documentConfiguration
                    == card.documentConfiguration
            )
            #expect(
                runtime.controller.historyAvailabilityForTesting.canUndo
                    == false
            )
            #expect(
                runtime.controller.historyAvailabilityForTesting.canRedo
                    == false
            )

            let replay = try await runtime.session.replaySelectedReviewCard()
            #expect(replay.cardID == card.cardID)
            #expect(
                replay.snapshot.documentConfiguration
                    == card.documentConfiguration
            )
            #expect(replay.snapshot.documentDomainLocked)
        }
    }

    @Test
    func latestProfessionalSelectionWinsConcurrentCompilation() async throws {
        let gate = ProfessionalCompilationGate(
            definitionID:
                ProfessionalBrushCatalog.graphitePencil.id.rawValue
        )
        guard let runtime = try makeRuntime(
            compilerHooks: BrushCompilerTestHooks { context in
                await gate.pauseFirstMatching(context)
            }
        ) else {
            return
        }
        runtime.session.selectReviewMatrix(.stageFiveProfessional)
        let superseded = try #require(
            runtime.session.professionalManualCards.first {
                $0.brushID
                    == ProfessionalBrushCatalog.graphitePencil.id.rawValue
                    && $0.gesture == .slowLine
            }
        )
        let latest = try #require(
            runtime.session.professionalManualCards.first {
                $0.brushID
                    == ProfessionalBrushCatalog.technicalInk.id.rawValue
                    && $0.gesture == .periodicSeamCrossing
            }
        )

        let supersededSelection = Task {
            try await runtime.session.selectReviewCard(superseded.cardID)
        }
        await gate.waitUntilPaused()
        try await runtime.session.selectReviewCard(latest.cardID)
        gate.resume()

        await #expect(throws: CancellationError.self) {
            try await supersededSelection.value
        }
        #expect(
            runtime.session.selectedProfessionalManualCardID
                == latest.cardID
        )
        #expect(
            runtime.session.compiledBrush?.renderIdentity.definitionID
                == ProfessionalBrushCatalog.technicalInk.id
        )
        #expect(
            runtime.controller.renderer.documentConfiguration
                == latest.documentConfiguration
        )
    }

    @Test
    func stageFourSelectionSupersedesPausedProfessionalSelectionExactly()
        async throws
    {
        let gate = ProfessionalCompilationGate(
            definitionID:
                ProfessionalBrushCatalog.graphitePencil.id.rawValue
        )
        guard let runtime = try makeRuntime(
            compilerHooks: BrushCompilerTestHooks { context in
                await gate.pauseFirstMatching(context)
            }
        ) else {
            return
        }
        runtime.session.selectReviewMatrix(.stageFiveProfessional)
        let superseded = try #require(
            runtime.session.professionalManualCards.first {
                $0.brushID
                    == ProfessionalBrushCatalog.graphitePencil.id.rawValue
                    && $0.gesture == .periodicSeamCrossing
            }
        )
        let winning = try #require(
            runtime.session.manualCards.first {
                $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                    && $0.documentMode == "plain"
                    && !$0.predictionEnabled
                    && $0.customResourceFixture == nil
            }
        )

        let supersededSelection = Task {
            try await runtime.session.selectReviewCard(superseded.cardID)
        }
        await gate.waitUntilPaused()
        runtime.session.selectReviewMatrix(.stageFourDiagnostic)
        try await runtime.session.selectReviewCard(winning.cardID)
        _ = try await runtime.session.replaySelectedReviewCard()
        let winningState = try professionalReviewSnapshot(runtime)
        gate.resume()

        await #expect(throws: CancellationError.self) {
            try await supersededSelection.value
        }
        #expect(try professionalReviewSnapshot(runtime) == winningState)
        #expect(
            runtime.controller.renderer.documentConfiguration
                == winning.documentConfiguration
        )
        #expect(
            runtime.controller.renderer.preparedBrush(for: .draw)?
                .renderIdentity
                == runtime.session.compiledBrush?.renderIdentity
        )
    }

    @Test
    func professionalSelectionSupersedesPausedStageFourSelectionExactly()
        async throws
    {
        let gate = ProfessionalCompilationGate(
            definitionID: AnchorBrushCatalog.ink.id.rawValue
        )
        guard let runtime = try makeRuntime(
            compilerHooks: BrushCompilerTestHooks { context in
                await gate.pauseFirstMatching(context)
            }
        ) else {
            return
        }
        let superseded = try #require(
            runtime.session.manualCards.first {
                $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                    && $0.documentMode == "plain"
                    && !$0.predictionEnabled
                    && $0.customResourceFixture == nil
            }
        )
        let winning = try #require(
            runtime.session.professionalManualCards.first {
                $0.brushID
                    == ProfessionalBrushCatalog.technicalInk.id.rawValue
                    && $0.gesture == .slowLine
            }
        )

        let supersededSelection = Task {
            try await runtime.session.selectReviewCard(superseded.cardID)
        }
        await gate.waitUntilPaused()
        runtime.session.selectReviewMatrix(.stageFiveProfessional)
        try await runtime.session.selectReviewCard(winning.cardID)
        _ = try await runtime.session.replaySelectedReviewCard()
        let winningState = try professionalReviewSnapshot(runtime)
        gate.resume()

        await #expect(throws: CancellationError.self) {
            try await supersededSelection.value
        }
        #expect(try professionalReviewSnapshot(runtime) == winningState)
        #expect(
            runtime.controller.renderer.documentConfiguration
                == winning.documentConfiguration
        )
        #expect(
            runtime.controller.renderer.preparedBrush(for: .draw)?
                .renderIdentity
                == runtime.session.compiledBrush?.renderIdentity
        )
    }

    @Test
    func failedProfessionalCompilationPreservesEveryReviewObservable()
        async throws
    {
        guard let runtime = try makeRuntime(
            brushCacheBudgetBytes: 64 * 1_024
        ) else {
            return
        }
        runtime.session.selectReviewMatrix(.stageFiveProfessional)
        let technical = try #require(
            runtime.session.professionalManualCards.first {
                $0.brushID
                    == ProfessionalBrushCatalog.technicalInk.id.rawValue
                    && $0.gesture == .eraserRetrace
            }
        )
        let graphite = try #require(
            runtime.session.professionalManualCards.first {
                $0.brushID
                    == ProfessionalBrushCatalog.graphitePencil.id.rawValue
                    && $0.gesture == .radialRotation
            }
        )
        try await runtime.session.selectReviewCard(technical.cardID)
        _ = try await runtime.session.replaySelectedReviewCard()
        let before = try professionalReviewSnapshot(runtime)

        await #expect(throws: BrushCompilationFailure.self) {
            try await runtime.session.selectReviewCard(graphite.cardID)
        }

        let after = try professionalReviewSnapshot(runtime)
        #expect(after == before)
    }

    @Test
    func failedProfessionalResetRollsBackEveryCompilerAndReviewObservable()
        async throws
    {
        var forceClearFailure = false
        guard let runtime = try makeRuntime(
            forceClearFailure: { forceClearFailure }
        ) else {
            return
        }
        runtime.session.selectReviewMatrix(.stageFiveProfessional)
        let retained = try #require(
            runtime.session.professionalManualCards.first {
                $0.brushID
                    == ProfessionalBrushCatalog.technicalInk.id.rawValue
                    && $0.gesture == .eraserRetrace
            }
        )
        let rejected = try #require(
            runtime.session.professionalManualCards.first {
                $0.brushID
                    == ProfessionalBrushCatalog.graphitePencil.id.rawValue
                    && $0.gesture == .periodicSeamCrossing
            }
        )
        try await runtime.session.selectReviewCard(retained.cardID)
        _ = try await runtime.session.replaySelectedReviewCard()
        let before = try professionalReviewSnapshot(runtime)

        forceClearFailure = true
        await #expect(throws: MetalRendererError.self) {
            try await runtime.session.selectReviewCard(rejected.cardID)
        }

        #expect(try professionalReviewSnapshot(runtime) == before)
    }

    @Test
    func professionalManualAssessmentsStartUnsetAndRemainUserOwned() {
        let assessment = BrushLabProfessionalManualAssessment(
            cardID: "builtin.professional-technical-ink.manual"
        )

        #expect(assessment.responsiveness == nil)
        #expect(assessment.edgeQuality == nil)
        #expect(assessment.taperTermination == nil)
        #expect(assessment.textureCohesion == nil)
        #expect(assessment.pressureResponse == nil)
        #expect(assessment.tiltDirectionResponse == nil)
        #expect(assessment.buildup == nil)
        #expect(assessment.symmetryBehavior == nil)
        #expect(assessment.eraserMatch == nil)
        #expect(assessment.notes == nil)
    }

    @Test
    func professionalManualExportIsSeparateFromStageFourDiagnosticEvidence()
        throws
    {
        let stageFour = try BrushLabManualCatalog.pending().encoded()
        let professional = try BrushLabProfessionalManualCatalog.pending()
            .encoded()
        let decoded = try JSONDecoder().decode(
            BrushLabProfessionalManualCatalog.self,
            from: professional
        )

        #expect(stageFour != professional)
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.cards == BrushLabManualCard.professionalFixedMatrix)
        #expect(decoded.assessments.allSatisfy {
            $0.responsiveness == nil
                && $0.edgeQuality == nil
                && $0.taperTermination == nil
                && $0.textureCohesion == nil
                && $0.pressureResponse == nil
                && $0.tiltDirectionResponse == nil
                && $0.buildup == nil
                && $0.symmetryBehavior == nil
                && $0.eraserMatch == nil
                && $0.notes == nil
        })

        guard let runtime = try makeRuntime() else { return }
        #expect(try runtime.session.makeProfessionalManualCardsData()
            == professional)
    }

    @Test
    func professionalManualArtifactValidatorRequiresExactUserOwnedEvidence()
        throws
    {
        let pending = try BrushLabProfessionalManualCatalog.pending()
            .encoded()
        #expect(
            try ProfessionalManualEvidenceValidator.validate(pending)
                == false
        )

        let cards = BrushLabProfessionalManualCard.fixedMatrix
        let complete = BrushLabProfessionalManualCatalog(
            cards: cards,
            assessments: cards.map {
                BrushLabProfessionalManualAssessment(
                    cardID: $0.cardID,
                    responsiveness: "pass",
                    edgeQuality: "pass",
                    taperTermination: "pass",
                    textureCohesion: "pass",
                    pressureResponse: "pass",
                    tiltDirectionResponse: "pass",
                    buildup: "pass",
                    symmetryBehavior: "pass",
                    eraserMatch: "pass",
                    notes: "reviewed"
                )
            }
        )
        #expect(
            try ProfessionalManualEvidenceValidator.validate(
                try complete.encoded()
            )
        )

        var object = try #require(
            JSONSerialization.jsonObject(with: pending)
                as? [String: Any]
        )
        var mutatedCards = try #require(
            object["cards"] as? [[String: Any]]
        )
        mutatedCards[0]["gesture"] = "unknown"
        object["cards"] = mutatedCards
        #expect(throws: Error.self) {
            _ = try ProfessionalManualEvidenceValidator.validate(
                try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
            )
        }
    }

    @Test
    func professionalManualValidatorRejectsNestedSchemaAndSemanticMutations()
        throws
    {
        let pending = try BrushLabProfessionalManualCatalog.pending()
            .encoded()
        #expect(
            ProfessionalBrushTruth.canonicalManualCardsSHA256
                == "ef36da0a12c26ea335032b4f596005b762617da6f7057fe47ffc1031872fdf5e"
        )
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("root key", { $0["unexpected"] = true }),
            ("catalog schema", { $0["schemaVersion"] = 2 }),
            ("card key", { object in
                var cards = object["cards"] as! [[String: Any]]
                cards[0]["unexpected"] = true
                object["cards"] = cards
            }),
            ("card schema", { object in
                var cards = object["cards"] as! [[String: Any]]
                cards[0]["schemaVersion"] = 1
                object["cards"] = cards
            }),
            ("pass key", { object in
                var cards = object["cards"] as! [[String: Any]]
                var passes = cards[0]["passes"] as! [[String: Any]]
                passes[0]["unexpected"] = true
                cards[0]["passes"] = passes
                object["cards"] = cards
            }),
            ("pass role", { object in
                var cards = object["cards"] as! [[String: Any]]
                var passes = cards[0]["passes"] as! [[String: Any]]
                passes[0]["role"] = "substrate"
                cards[0]["passes"] = passes
                object["cards"] = cards
            }),
            ("pass source", { object in
                var cards = object["cards"] as! [[String: Any]]
                var passes = cards[0]["passes"] as! [[String: Any]]
                passes[0]["inputSource"] = "mouse"
                cards[0]["passes"] = passes
                object["cards"] = cards
            }),
            ("stroke key", { object in
                var cards = object["cards"] as! [[String: Any]]
                var passes = cards[0]["passes"] as! [[String: Any]]
                var strokes = passes[0]["strokes"] as! [[String: Any]]
                strokes[0]["unexpected"] = true
                passes[0]["strokes"] = strokes
                cards[0]["passes"] = passes
                object["cards"] = cards
            }),
            ("sample key", { object in
                var cards = object["cards"] as! [[String: Any]]
                var passes = cards[0]["passes"] as! [[String: Any]]
                var strokes = passes[0]["strokes"] as! [[String: Any]]
                var samples = strokes[0]["samples"] as! [[String: Any]]
                samples[0]["unexpected"] = true
                strokes[0]["samples"] = samples
                passes[0]["strokes"] = strokes
                cards[0]["passes"] = passes
                object["cards"] = cards
            }),
            ("sample pressure type", { object in
                var cards = object["cards"] as! [[String: Any]]
                var passes = cards[0]["passes"] as! [[String: Any]]
                var strokes = passes[0]["strokes"] as! [[String: Any]]
                var samples = strokes[0]["samples"] as! [[String: Any]]
                samples[0]["pressure"] = true
                strokes[0]["samples"] = samples
                passes[0]["strokes"] = strokes
                cards[0]["passes"] = passes
                object["cards"] = cards
            }),
            ("assessment key", { object in
                var values =
                    object["assessments"] as! [[String: Any]]
                values[0]["unexpected"] = true
                object["assessments"] = values
            }),
            ("assessment value", { object in
                var values =
                    object["assessments"] as! [[String: Any]]
                values[0]["responsiveness"] = "approved"
                object["assessments"] = values
            }),
        ]
        for (name, mutate) in mutations {
            var object = try #require(
                JSONSerialization.jsonObject(with: pending)
                    as? [String: Any]
            )
            mutate(&object)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            #expect(throws: Error.self, "\(name)") {
                _ = try ProfessionalManualEvidenceValidator.validate(data)
            }
        }
    }

    @Test
    func professionalManualValidatorReportsEveryScenarioSemanticBeforeDigest()
        throws
    {
        let pending = try BrushLabProfessionalManualCatalog.pending()
            .encoded()
        let cases: [
            (
                String,
                String,
                (inout [String: Any], Int) -> Void
            )
        ] = [
            ("tap", "professional manual semantic: tap", {
                object, index in
                mutateProfessionalStroke(
                    in: &object,
                    cardIndex: index
                ) {
                    var samples = $0["samples"] as! [[String: Any]]
                    samples.remove(at: 1)
                    samples[1]["sampleIndex"] = 1
                    $0["samples"] = samples
                }
            }),
            ("slowLine", "professional manual semantic: lineTiming", {
                object, index in
                mutateProfessionalSample(
                    in: &object,
                    cardIndex: index,
                    sampleIndex: 1
                ) {
                    $0["timeOffset"] = 0.049
                }
            }),
            ("fastLine", "professional manual semantic: lineTiming", {
                object, index in
                mutateProfessionalSample(
                    in: &object,
                    cardIndex: index,
                    sampleIndex: 2
                ) {
                    $0["y"] = 127
                }
            }),
            ("pressureRamp", "professional manual semantic: pressureRamp", {
                object, index in
                mutateProfessionalSample(
                    in: &object,
                    cardIndex: index,
                    sampleIndex: 2
                ) {
                    $0["pressure"] = 0.6
                }
            }),
            ("tiltSweep", "professional manual semantic: tiltSweep", {
                object, index in
                mutateProfessionalSample(
                    in: &object,
                    cardIndex: index,
                    sampleIndex: 1
                ) {
                    $0["azimuth"] = 0.6
                }
            }),
            ("curve", "professional manual semantic: curve", {
                object, index in
                mutateProfessionalSample(
                    in: &object,
                    cardIndex: index,
                    sampleIndex: 2
                ) {
                    $0["x"] = 113
                }
            }),
            ("sharpCorner", "professional manual semantic: sharpCorner", {
                object, index in
                mutateProfessionalSample(
                    in: &object,
                    cardIndex: index,
                    sampleIndex: 1
                ) {
                    $0["y"] = 191
                }
            }),
            ("crossHatch", "professional manual semantic: crossHatch", {
                object, index in
                mutateProfessionalSample(
                    in: &object,
                    cardIndex: index,
                    strokeIndex: 3,
                    sampleIndex: 1
                ) {
                    $0["y"] = 73
                }
            }),
            (
                "repeatedBuildup",
                "professional manual semantic: repeatedBuildup",
                { object, index in
                    mutateProfessionalSample(
                        in: &object,
                        cardIndex: index,
                        strokeIndex: 3,
                        sampleIndex: 2
                    ) {
                        $0["x"] = 129
                    }
                }
            ),
            (
                "periodicSeamCrossing",
                "professional manual semantic: periodicSeamCrossing",
                { object, index in
                    mutateProfessionalSample(
                        in: &object,
                        cardIndex: index,
                        sampleIndex: 0
                    ) {
                        $0["x"] = 5
                    }
                }
            ),
            (
                "radialRotation",
                "professional manual semantic: radialRotation",
                { object, index in
                    mutateProfessionalDocument(
                        in: &object,
                        cardIndex: index
                    ) {
                        $0["rayCount"] = 7
                    }
                }
            ),
            (
                "radialReflection",
                "professional manual semantic: radialReflection",
                { object, index in
                    mutateProfessionalDocument(
                        in: &object,
                        cardIndex: index
                    ) {
                        $0["centerX"] = 1_023
                    }
                }
            ),
            (
                "eraserRetrace",
                "professional manual semantic: eraserRetrace",
                { object, index in
                    mutateProfessionalSample(
                        in: &object,
                        cardIndex: index,
                        passIndex: 1,
                        sampleIndex: 2
                    ) {
                        $0["x"] = 129
                    }
                }
            ),
            (
                "mouseFallback",
                "professional manual semantic: mouseFallback",
                { object, index in
                    mutateProfessionalSample(
                        in: &object,
                        cardIndex: index,
                        sampleIndex: 2
                    ) {
                        $0["pressure"] = 0.9
                    }
                }
            ),
            (
                "tabletInput",
                "professional manual semantic: tabletInput",
                { object, index in
                    mutateProfessionalSample(
                        in: &object,
                        cardIndex: index,
                        sampleIndex: 4
                    ) {
                        $0["roll"] = 0.25
                    }
                }
            ),
        ]

        for (gesture, expectedError, mutate) in cases {
            var object = try #require(
                JSONSerialization.jsonObject(with: pending)
                    as? [String: Any]
            )
            let cards = try #require(
                object["cards"] as? [[String: Any]]
            )
            let cardIndex = try #require(cards.firstIndex {
                $0["gesture"] as? String == gesture
            })
            mutate(&object, cardIndex)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            do {
                try ProfessionalManualEvidenceValidator.validateSemantics(
                    data
                )
                Issue.record(
                    "Semantic boundary accepted invalid \(gesture)"
                )
            } catch {
                #expect(
                    error.localizedDescription == expectedError,
                    "\(gesture) boundary: \(error.localizedDescription)"
                )
            }
            do {
                _ = try ProfessionalManualEvidenceValidator.validate(data)
                Issue.record("Accepted invalid \(gesture) semantics")
            } catch {
                #expect(
                    error.localizedDescription == expectedError,
                    "\(gesture): \(error.localizedDescription)"
                )
            }
        }
    }

    @Test
    func professionalManualValidatorChecksEveryScenarioLabelBeforeDigest()
        throws
    {
        let pending = try BrushLabProfessionalManualCatalog.pending()
            .encoded()
        let expectedErrors = [
            "tap": "professional manual semantic: tap",
            "slowLine": "professional manual semantic: lineTiming",
            "fastLine": "professional manual semantic: lineTiming",
            "pressureRamp": "professional manual semantic: pressureRamp",
            "tiltSweep": "professional manual semantic: tiltSweep",
            "curve": "professional manual semantic: curve",
            "sharpCorner": "professional manual semantic: sharpCorner",
            "crossHatch": "professional manual semantic: crossHatch",
            "repeatedBuildup":
                "professional manual semantic: repeatedBuildup",
            "periodicSeamCrossing":
                "professional manual semantic: periodicSeamCrossing",
            "radialRotation":
                "professional manual semantic: radialRotation",
            "radialReflection":
                "professional manual semantic: radialReflection",
            "eraserRetrace":
                "professional manual semantic: eraserRetrace",
            "mouseFallback":
                "professional manual semantic: mouseFallback",
            "tabletInput":
                "professional manual semantic: tabletInput",
        ]
        let canonical = try #require(
            JSONSerialization.jsonObject(with: pending)
                as? [String: Any]
        )
        let canonicalCards = try #require(
            canonical["cards"] as? [[String: Any]]
        )

        for gesture in expectedErrors.keys.sorted() {
            let cardIndex = try #require(canonicalCards.firstIndex {
                $0["gesture"] as? String == gesture
            })
            let expectedError = expectedErrors[gesture]!
            let canonicalCard = canonicalCards[cardIndex]
            let paint = try #require(
                canonicalCard["paintRGBAHex"] as? String
            )
            let background = try #require(
                canonicalCard["background"] as? String
            )

            var paintMutation = canonical
            var paintCards =
                paintMutation["cards"] as! [[String: Any]]
            paintCards[cardIndex]["paintRGBAHex"] =
                paint == "#111111FF" ? "#C43A52FF" : "#111111FF"
            paintMutation["cards"] = paintCards
            try expectProfessionalSemanticFailure(
                paintMutation,
                gesture: gesture,
                mutation: "paint",
                expectedError: expectedError
            )

            var backgroundMutation = canonical
            var backgroundCards =
                backgroundMutation["cards"] as! [[String: Any]]
            backgroundCards[cardIndex]["background"] =
                background == "opaque" ? "transparent" : "opaque"
            backgroundMutation["cards"] = backgroundCards
            try expectProfessionalSemanticFailure(
                backgroundMutation,
                gesture: gesture,
                mutation: "background",
                expectedError: expectedError
            )

            guard gesture != "tap" else { continue }
            var suffixMutation = canonical
            var suffixCards =
                suffixMutation["cards"] as! [[String: Any]]
            let cardID = try #require(
                suffixCards[cardIndex]["cardID"] as? String
            )
            #expect(cardID.hasSuffix(".standard"))
            suffixCards[cardIndex]["cardID"] =
                String(cardID.dropLast("standard".count)) + "alternate"
            suffixMutation["cards"] = suffixCards
            try expectProfessionalSemanticFailure(
                suffixMutation,
                gesture: gesture,
                mutation: "variant",
                expectedError: expectedError
            )
        }
    }

    @Test
    func professionalMatrixExportCoordinatorWritesTheSessionReviewArtifact()
        throws
    {
        guard let runtime = try makeRuntime() else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(
            "professional-review-matrix.json"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try BrushLabProfessionalMatrixExportCoordinator.live.export(
            runtime.session,
            to: destination
        )

        let artifact = try Data(contentsOf: destination)
        let catalog = try JSONDecoder().decode(
            BrushLabProfessionalManualCatalog.self,
            from: artifact
        )
        #expect(catalog.schemaVersion == 3)
        #expect(catalog.cards == BrushLabManualCard.professionalFixedMatrix)
        #expect(Set(catalog.cards.map(\.brushID)) == Set(
            ProfessionalBrushCatalog.all.map(\.id.rawValue)
        ))
        #expect(catalog.assessments.allSatisfy {
            $0.responsiveness == nil
                && $0.edgeQuality == nil
                && $0.taperTermination == nil
                && $0.textureCohesion == nil
                && $0.pressureResponse == nil
                && $0.tiltDirectionResponse == nil
                && $0.buildup == nil
                && $0.symmetryBehavior == nil
                && $0.eraserMatch == nil
                && $0.notes == nil
        })
    }

    @Test
    func fixedManualCardMatrixCoversEveryAnchorAndRequiredDimension() {
        let cards = BrushLabManualCard.fixedMatrix
        let anchorIDs = Set(AnchorBrushCatalog.all.map(\.id.rawValue))

        #expect(cards.count == 312)
        #expect(cards.map(\.cardID) == cards.map(\.cardID).sorted())
        #expect(Set(cards.map(\.cardID)).count == cards.count)
        #expect(Set(cards.map(\.brushID)) == anchorIDs)

        for anchorID in anchorIDs {
            let anchorCards = cards.filter { $0.brushID == anchorID }
            #expect(anchorCards.count == 52)
            #expect(Set(anchorCards.map(\.gesture)) == [
                .tap,
                .slowLine,
                .fastLine,
                .curve,
                .zigZag,
                .directionReversal,
            ])
            #expect(Set(anchorCards.map(\.diameter)) == [2, 20, 2_000])
            #expect(Set(anchorCards.map(\.pressureProfile)) == [
                "high",
                "low",
                "medium",
            ])
            #expect(Set(anchorCards.map(\.documentMode)) == [
                "finite-radial",
                "periodic",
                "plain",
                "reflected",
            ])
            #expect(Set(anchorCards.map(\.background)) == [
                .opaque,
                .transparent,
            ])
            #expect(Set(anchorCards.map(\.predictionEnabled)) == [
                false,
                true,
            ])
            #expect(anchorCards.contains {
                $0.inputCapabilities == [
                    "pressure",
                    "altitude",
                    "azimuth",
                    "roll",
                ]
            })
            #expect(anchorCards.contains {
                $0.customResourceFixture
                    == "custom-asymmetric-shape-grain-v1"
            })
            #expect(anchorCards.contains {
                $0.customResourceFixture == nil
            })
        }
    }

    @Test
    func manualCardScheduleProvidesFullPairwiseFactorCoveragePerAnchor() {
        let anchorID = AnchorBrushCatalog.ink.id.rawValue
        let cards = BrushLabManualCard.fixedMatrix.filter {
            $0.brushID == anchorID
        }
        let rows = cards.map { card in
            [
                card.gesture.rawValue,
                String(card.diameter),
                card.pressureProfile,
                card.inputCapabilities.joined(separator: "+"),
                card.documentMode,
                card.background.rawValue,
                card.predictionEnabled ? "on" : "off",
                card.paintRGBAHex,
                card.customResourceFixture ?? "builtin",
            ]
        }
        let literalLevelCounts = [6, 3, 3, 4, 4, 2, 2, 3, 2]

        for first in literalLevelCounts.indices {
            for second in literalLevelCounts.indices where second > first {
                let pairs = Set(rows.map {
                    "\($0[first])|\($0[second])"
                })
                #expect(
                    pairs.count
                        == literalLevelCounts[first]
                            * literalLevelCounts[second],
                    "Factors \(first) and \(second) remain coupled"
                )
            }
        }
    }

    @Test
    func freshSessionsProduceByteIdenticalManualCardJSON() throws {
        guard let first = try makeRuntime(),
              let second = try makeRuntime()
        else {
            return
        }

        let firstData = try first.session.makeManualCardsData()
        let secondData = try second.session.makeManualCardsData()
        let headlessData = try BrushLabManualCatalog.pending().encoded()

        #expect(firstData == secondData)
        #expect(firstData == headlessData)
        #expect(
            BrushContentHash.sha256Hex(of: firstData)
                == "6490bcf5d3d452e523b0eba7293b1bf8050ae8445a41941592bbb60c91bf7a32"
        )
    }

    @Test
    func manualAssessmentsStartUnsetAndNeverSelfApprove() {
        let assessment = BrushLabManualAssessment(
            cardID: "builtin.native-ink.tap.minimum.low"
        )

        #expect(assessment.responsiveness == nil)
        #expect(assessment.edgeQuality == nil)
        #expect(assessment.textureCohesion == nil)
        #expect(assessment.buildup == nil)
        #expect(assessment.symmetryBehavior == nil)
        #expect(assessment.eraserMatch == nil)
        #expect(assessment.notes == nil)
    }

    @Test
    func selectsAndReplaysManualCardThroughProductionController()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.gesture == .tap
                && $0.documentMode == "periodic"
                && $0.predictionEnabled
                && $0.customResourceFixture == nil
        })

        try await runtime.session.selectManualCard(card.cardID)
        let generation = try await runtime.session.replaySelectedManualCard()

        #expect(runtime.session.selectedManualCardID == card.cardID)
        #expect(generation.cardID == card.cardID)
        #expect(runtime.session.package?.definition.id.rawValue == card.brushID)
        #expect(runtime.controller.model.brushDiameter == card.diameter)
        #expect(runtime.controller.model.inkColor == card.paintColor)
        #expect(runtime.session.inputRecords == card.traceSamples().enumerated()
            .map { BrushLabInputRecord(sequence: $0.offset, sample: $0.element) })
        #expect(runtime.session.inputRecords.contains {
            $0.kind == "predicted"
        })
        #expect(!runtime.session.dabRecords.isEmpty)
        #expect(runtime.controller.renderer.isIdle)
        #expect(
            runtime.session.compiledBrush?.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
    }

    @Test
    func repeatedReplayProducesIdenticalPixelsAndTraceWithoutHarnessHelper()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.documentMode == "plain"
                && !$0.predictionEnabled
                && $0.customResourceFixture == nil
        })
        try await runtime.session.selectManualCard(card.cardID)

        let first = try await runtime.session.replaySelectedManualCard()
        let firstArchive = try runtime.session.makeManualEvidenceArchive()
        let second = try await runtime.session.replaySelectedManualCard()
        let secondArchive = try runtime.session.makeManualEvidenceArchive()

        #expect(first.canvasHash == second.canvasHash)
        #expect(first.traceHash == second.traceHash)
        #expect(firstArchive.files["canvas.png"]
            == secondArchive.files["canvas.png"])
        #expect(first.input == second.input)
        #expect(first.logicalDabs == second.logicalDabs)
        #expect(runtime.controller.renderer.isIdle)
    }

    @Test
    func failedAwaitedClearPreservesPixelsProducesNoEvidenceAndRecovers()
        async throws
    {
        var forceClearFailure = false
        guard let runtime = try makeRuntime(
            forceClearFailure: { forceClearFailure }
        ) else {
            return
        }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.documentMode == "plain"
                && !$0.predictionEnabled
                && $0.customResourceFixture == nil
        })
        try await runtime.session.selectManualCard(card.cardID)
        let baseline = try await runtime.session.replaySelectedManualCard()
        let baselineSnapshot = try runtime.controller.renderer
            .captureCommittedDocument()

        forceClearFailure = true
        await #expect(throws: MetalRendererError.self) {
            try await runtime.session.replaySelectedManualCard()
        }
        #expect(
            try runtime.controller.renderer.captureCommittedDocument()
                == baselineSnapshot
        )
        #expect(runtime.session.completedReplay == nil)
        #expect(throws: BrushLabEvidenceError.completedReplayUnavailable) {
            try runtime.session.makeManualEvidenceArchive()
        }

        forceClearFailure = false
        let recovered =
            try await runtime.session.replaySelectedManualCard()
        #expect(recovered.canvasHash == baseline.canvasHash)
        #expect(recovered.traceHash == baseline.traceHash)
        #expect(runtime.controller.renderer.isIdle)
    }

    @Test
    func exportRemainsBoundToCompletedCardAfterMutableUIStateChanges()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.documentMode == "plain"
        })
        try await runtime.session.selectManualCard(card.cardID)
        let generation = try await runtime.session.replaySelectedManualCard()

        runtime.controller.handleTool(.erase)
        runtime.controller.handleInkColor(
            InkColor(red: 1, green: 1, blue: 1, alpha: 1)!
        )
        runtime.controller.model.confirmBrushDiameter(137)
        let archive = try runtime.session.makeManualEvidenceArchive()
        let evidence = try #require(archive.files["evidence.json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: evidence)
                as? [String: Any]
        )
        let exportedCard = try #require(
            object["card"] as? [String: Any]
        )

        #expect(object["generationID"] as? String == generation.generationID)
        #expect(object["cardID"] as? String == card.cardID)
        #expect(exportedCard["paintRGBAHex"] as? String == card.paintRGBAHex)
        #expect(exportedCard["tool"] as? String == card.tool.rawValue)
    }

    @Test
    func eraserReplayHasVisibleReproducibleProductionSubstrate()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.eraser.id.rawValue
                && $0.documentMode == "plain"
                && !$0.predictionEnabled
        })
        try await runtime.session.selectManualCard(card.cardID)

        let first = try await runtime.session.replaySelectedManualCard()
        let firstPNG = try #require(
            runtime.session.makeManualEvidenceArchive().files["canvas.png"]
        )
        let second = try await runtime.session.replaySelectedManualCard()
        let secondArchive = try runtime.session.makeManualEvidenceArchive()
        let secondPNG = try #require(secondArchive.files["canvas.png"])
        let evidence = try #require(secondArchive.files["evidence.json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: evidence)
                as? [String: Any]
        )

        #expect(card.substrate != .none)
        #expect(first.canvasHash == second.canvasHash)
        #expect(firstPNG == secondPNG)
        #expect(first.substrateInputCount > 0)
        #expect((object["substrate"] as? [String: Any])?["kind"] as? String
            == card.substrate.rawValue)
        #expect(Set(second.input.map(\.source)) == ["mouse"])
    }

    @Test
    func syntheticCardsCannotClaimPhysicalPencilOrWacomEvidence()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.inputCapabilities.contains("roll")
                && $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.documentMode == "plain"
        })
        try await runtime.session.selectManualCard(card.cardID)
        _ = try await runtime.session.replaySelectedManualCard()
        let evidence = try #require(
            runtime.session.makeManualEvidenceArchive()
                .files["evidence.json"]
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: evidence)
                as? [String: Any]
        )
        let physical = try #require(
            object["physicalDeviceStatus"] as? [String: Any]
        )

        #expect(object["inputOrigin"] as? String == "synthetic")
        #expect(physical["pencil"] as? String == "pending")
        #expect(physical["wacom"] as? String == "pending")
        #expect(Set(runtime.session.inputRecords.map(\.source)) == ["mouse"])
        #expect(runtime.session.inputRecords.contains {
            $0.capabilities != 0
        })
    }

    @Test
    func decodedCardRejectsPaintMutationUnderAStaleStableID() throws {
        let card = try #require(BrushLabManualCard.fixedMatrix.first {
            $0.paintRGBAHex == "#111111FF"
        })
        let data = try JSONEncoder().encode(card)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["paintRGBAHex"] = "#C43A52FF"
        let mutated = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                BrushLabManualCard.self,
                from: mutated
            )
        }
    }

    @Test
    func decodedCardRejectsEverySymmetryMutationUnderAStaleStableID()
        throws
    {
        let periodic = try #require(
            BrushLabManualCard.fixedMatrix.first {
                $0.documentMode == "periodic"
            }
        )
        for mutation in [
            ("mode", "plain" as Any),
            ("presetID", SymmetryPresetID.halfDrop.rawValue as Any),
            ("repeatWidth", 317.25 as Any),
            ("repeatHeight", 193.5 as Any),
            ("orientationRadians", 0.375 as Any),
        ] {
            try expectStaleDocumentMutationRejected(
                periodic,
                key: mutation.0,
                value: mutation.1
            )
        }

        let radial = try #require(
            BrushLabManualCard.fixedMatrix.first {
                $0.documentMode == "finite-radial"
            }
        )
        for mutation in [
            ("mode", "plain" as Any),
            ("radialKind", RadialSymmetryKind.rotation.rawValue as Any),
            ("rayCount", 11 as Any),
            ("centerX", 997.25 as Any),
            ("centerY", 1043.75 as Any),
            ("referenceAngleRadians", 0.25 as Any),
        ] {
            try expectStaleDocumentMutationRejected(
                radial,
                key: mutation.0,
                value: mutation.1
            )
        }
    }

    @Test
    func decodedCardRejectsUnknownFixtureEvenWithMatchingFixtureIdentity()
        throws
    {
        let card = try #require(BrushLabManualCard.fixedMatrix.first {
            $0.customResourceFixture
                == BrushLabManualCard.customAsymmetricFixture
        })
        let data = try JSONEncoder().encode(card)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let unknown = "custom-asymmetric-shape-grain-v2"
        object["customResourceFixture"] = unknown
        object["cardID"] = card.cardID.replacingOccurrences(
            of: BrushLabManualCard.customAsymmetricFixture,
            with: unknown
        )
        let mutated = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                BrushLabManualCard.self,
                from: mutated
            )
        }
    }

    @Test
    func manualEvidenceArchiveWritesJSONPNGsAndTelemetryAtomically()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.documentMode == "plain"
                && !$0.predictionEnabled
        })
        try await runtime.session.selectManualCard(card.cardID)
        _ = try await runtime.session.replaySelectedManualCard()

        let archive = try runtime.session.makeManualEvidenceArchive()
        #expect(Set(archive.files.keys) == [
            "canvas.png",
            "evidence.json",
            "telemetry.json",
        ])
        #expect(archive.files["canvas.png"]?.prefix(8) == Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ]))

        let evidence = try #require(archive.files["evidence.json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: evidence)
                as? [String: Any]
        )
        #expect(object["cardID"] as? String == card.cardID)
        let assessment = try #require(
            object["assessment"] as? [String: Any]
        )
        #expect(assessment["responsiveness"] is NSNull)
        #expect(assessment["edgeQuality"] is NSNull)
        let identity = try #require(
            object["renderIdentity"] as? [String: Any]
        )
        #expect(
            identity["semanticHash"] as? String
                == runtime.session.packageContentHash
        )
        let telemetry = try #require(
            archive.files["telemetry.json"]
        )
        let telemetryObject = try #require(
            JSONSerialization.jsonObject(with: telemetry)
                as? [String: Any]
        )
        let rendererDeposition = runtime.controller.renderer
            .brushLabDiagnosticSnapshot.deposition
        #expect(
            telemetryObject["bufferHighWater"] as? Int
                == rendererDeposition.strokeBufferLeaseHighWater
        )
        #expect(
            telemetryObject["bufferLifetimeHighWater"] as? Int
                == rendererDeposition.lifetimeBufferLeaseHighWater
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "laya-brush-lab-archive-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let destination = root.appendingPathComponent(
            "card.brushlabevidence",
            isDirectory: true
        )
        try archive.writeAtomically(to: destination)
        #expect(
            Set(
                try FileManager.default.contentsOfDirectory(
                    atPath: destination.path
                )
            ) == Set(archive.files.keys)
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: root.path
            ).allSatisfy { !$0.hasPrefix(".card.brushlabevidence.tmp-") }
        )
    }

    @Test
    func productionEvidenceSaverReplacesAtomicallyAndPreservesOnFailure()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "laya-brush-lab-production-save-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let destination = root.appendingPathComponent(
            "card.brushlabevidence",
            isDirectory: true
        )
        let first = BrushLabManualEvidenceArchive(files: [
            "canvas.png": Data([1]),
            "evidence.json": Data("first".utf8),
            "telemetry.json": Data("telemetry-1".utf8),
        ])
        let replacement = BrushLabManualEvidenceArchive(files: [
            "canvas.png": Data([2]),
            "evidence.json": Data("second".utf8),
            "telemetry.json": Data("telemetry-2".utf8),
        ])
        try BrushLabManualEvidenceSaveService.live.save(
            first,
            to: destination
        )
        try BrushLabManualEvidenceSaveService.live.save(
            replacement,
            to: destination
        )
        #expect(
            try Data(
                contentsOf: destination.appendingPathComponent(
                    "evidence.json"
                )
            ) == Data("second".utf8)
        )

        let failing = BrushLabManualEvidenceSaveService { data, url in
            if url.lastPathComponent == "telemetry.json" {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
        }
        #expect(throws: CocoaError.self) {
            try failing.save(first, to: destination)
        }
        #expect(
            try Data(
                contentsOf: destination.appendingPathComponent(
                    "evidence.json"
                )
            ) == Data("second".utf8)
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: root.path
            ).allSatisfy { !$0.contains(".tmp-") }
        )
    }

    @Test
    func customAsymmetricCardCompilesRealShapeAndGrainResources()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        let card = try #require(runtime.session.manualCards.first {
            $0.brushID == AnchorBrushCatalog.ink.id.rawValue
                && $0.customResourceFixture
                    == BrushLabManualCard.customAsymmetricFixture
                && $0.documentMode == "plain"
        })

        try await runtime.session.selectManualCard(card.cardID)

        #expect(
            Set(runtime.session.compiledBrush.map {
                Array($0.textures.keys)
            } ?? []) == [
                "brush-lab.custom-asymmetric.grain",
                "brush-lab.custom-asymmetric.shape",
            ]
        )
        #expect(runtime.session.package?.manifest.resources.count == 2)
        #expect(runtime.session.compilationReport?.residentResourceBytes ?? 0 > 0)
        #expect(
            runtime.session.compiledBrush?.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
    }

    @Test
    func loadsCompilesTracesAndExportsWithoutUIInteraction() async throws {
        guard let runtime = try makeRuntime() else { return }
        let package = try makePackage()

        await runtime.session.loadPackage(
            package,
            sourceName: "fixture.layabrush"
        )

        #expect(try runtime.session.packageContentHash == (package.contentHash))
        #expect(runtime.session.compilationReport != nil)
        #expect(runtime.session.drawingAvailability == .available)
        #expect(
            runtime.session.activeDrawingPackageContentHash
                == runtime.session.packageContentHash
        )
        #expect(runtime.session.settingGroups.count >= 5)

        let began = StrokeSample.mouse(
            position: ScreenPoint(x: 24, y: 24),
            timestamp: 1,
            phase: .began
        )
        runtime.controller.handleStrokeSample(began)
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 2,
                phase: .cancelled
            )
        )

        #expect(runtime.session.inputRecords.count == 2)
        #expect(!runtime.session.dabRecords.isEmpty)
        let evidence = try runtime.session.makeEvidenceData()
        let object = try #require(
            JSONSerialization.jsonObject(with: evidence)
                as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["package"] != nil)
        #expect(object["trace"] != nil)
        #expect(object["renderer"] != nil)
        let canvas = try #require(object["canvas"] as? [String: Any])
        let encodedPixels = try #require(
            canvas["singleRasterBGRA8Base64"] as? String
        )
        #expect(!encodedPixels.isEmpty)
        let compiler = try #require(object["compiler"] as? [String: Any])
        #expect((compiler["cacheBudgetBytes"] as? Int) ?? 0 > 0)
    }

    @Test
    func loadedPackageCanEraseItsOwnRenderedStroke() async throws {
        guard let runtime = try makeRuntime() else { return }
        await runtime.session.loadPackage(
            try makePackage(),
            sourceName: "eraser-fixture.layabrush"
        )
        runtime.controller.selectPlainCanvasMode()
        runtime.controller.model.confirmBrushDiameter(20)
        let stroke: [StrokeSample] = [
            .mouse(
                position: ScreenPoint(x: 20, y: 32),
                timestamp: 1,
                phase: .began
            ),
            .mouse(
                position: ScreenPoint(x: 44, y: 32),
                timestamp: 2,
                phase: .moved
            ),
            .mouse(
                position: ScreenPoint(x: 44, y: 32),
                timestamp: 3,
                phase: .ended
            ),
        ]

        runtime.controller.handleTool(.draw)
        runtime.controller.handleStrokeSamples(stroke)
        _ = try runtime.controller.renderer
            .completePendingInteractiveStroke()
        let painted = try #require(
            singleRasterBytes(
                runtime.controller.renderer.captureCommittedDocument()
            )
        )

        runtime.controller.handleTool(.erase)
        runtime.controller.handleStrokeSamples(stroke)
        _ = try runtime.controller.renderer
            .completePendingInteractiveStroke()
        let erased = try #require(
            singleRasterBytes(
                runtime.controller.renderer.captureCommittedDocument()
            )
        )

        #expect(alphaSum(painted) > 0)
        #expect(alphaSum(erased) < alphaSum(painted))
    }

    @Test
    func loadsConvertedPackageAndReportFromDiskWithoutUI() async throws {
        guard let runtime = try makeRuntime() else { return }
        let source = try SyntheticV1DiagnosticFixture.source(
            includeWet: false
        )
        let document = try #require(
            SyntheticV1BrushParser().parse(source).first
        )
        let mapped = try SyntheticV1BrushMapper().map(document)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "laya-brush-lab-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let packageURL = directory.appendingPathComponent(
            "converted.layabrush"
        )
        try BrushPackageIO.save(mapped.package, to: packageURL)

        await runtime.session.loadPackage(at: packageURL)

        #expect(runtime.session.errorMessage == nil)
        #expect(runtime.session.sourceName == "converted.layabrush")
        #expect(runtime.session.package?.manifest.schemaVersion == 2)
        #expect(runtime.session.package?.conversionReport == mapped.report)
        #expect(runtime.session.drawingAvailability == .available)
        let compiled = try #require(runtime.session.compiledBrush)
        #expect(Set(compiled.textures.keys) == [
            "grain.synthetic",
            "shape.synthetic",
        ])
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 1,
                phase: .began
            )
        )
        let activeStyle = try #require(
            runtime.controller.renderer.harnessActiveStrokeStyle
        )
        #expect(activeStyle.renderIdentity == compiled.renderIdentity)
        #expect(
            activeStyle.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 2,
                phase: .cancelled
            )
        )
        let evidence = try runtime.session.makeEvidenceData()
        let object = try #require(
            JSONSerialization.jsonObject(with: evidence)
                as? [String: Any]
        )
        let conversion = try #require(
            object["conversion"] as? [String: Any]
        )
        #expect(conversion["sourceFormat"] as? String == "synthetic")
        #expect(
            conversion["sourceContentHash"] as? String
                == mapped.report.sourceContentHash
        )
    }

    @Test
    func nativeOnlyProgramCompilesButIsNotSilentlyApproximated() async throws {
        guard let runtime = try makeRuntime() else { return }
        await runtime.session.loadPackage(
            try makePackage(),
            sourceName: "compatible.layabrush"
        )
        try await runtime.session.loadPackage(
            makePackage(nativeOnly: true),
            sourceName: "native-only.layabrush"
        )

        #expect(runtime.session.compilationReport != nil)
        #expect(
            runtime.session.drawingAvailability == .available
        )
        #expect(
            runtime.session.activeDrawingPackageContentHash
                == runtime.session.packageContentHash
        )
        #expect(
            runtime.session.compiledBrush?.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
        let compiled = try #require(runtime.session.compiledBrush)
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 1,
                phase: .began
            )
        )
        let activeStyle = try #require(
            runtime.controller.renderer.harnessActiveStrokeStyle
        )
        #expect(
            activeStyle.renderIdentity
                == compiled.renderIdentity
        )
        #expect(
            activeStyle.renderIdentity.semanticHash
                == runtime.session.packageContentHash
        )
        runtime.controller.handleStrokeSample(
            .mouse(
                position: ScreenPoint(x: 24, y: 24),
                timestamp: 2,
                phase: .cancelled
            )
        )
    }

    @Test
    func wetPackageRemainsInspectableWithTypedUnsupportedAvailability()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }

        await runtime.session.loadPackage(
            try makePackage(wet: true),
            sourceName: "wet.layabrush"
        )

        #expect(runtime.session.compilationReport?.backend == .canvasInteraction)
        #expect(
            runtime.session.drawingAvailability == .unsupportedInteraction(.wetMix)
        )
        #expect(runtime.session.compilationFailure == nil)
        #expect(runtime.session.compiledBrush == nil)
    }

    @Test
    func typedCompilationFailurePersistsUntilExplicitlyCleared()
        async throws
    {
        guard let runtime = try makeRuntime() else { return }
        await runtime.session.loadPackage(
            try makeCorruptResourcePackage(),
            sourceName: "corrupt.layabrush"
        )
        let failure = try #require(runtime.session.compilationFailure)
        #expect(failure.stage == .imageDecode)

        await runtime.session.loadPackage(
            try makePackage(),
            sourceName: "valid.layabrush"
        )
        #expect(runtime.session.drawingAvailability == .available)
        #expect(runtime.session.compilationFailure == failure)

        runtime.session.clearCompilationFailure()
        #expect(runtime.session.compilationFailure == nil)
    }

    private struct ProfessionalReviewDocumentSnapshot: Equatable {
        let canvasSize: PixelSize
        let documentConfiguration: SymmetryDocumentConfiguration
        let documentDomainLocked: Bool
        let radialGeometryLocked: Bool
        let storageHash: String

        init(_ snapshot: CommittedDocumentSnapshot) {
            canvasSize = snapshot.canvasSize
            documentConfiguration = snapshot.documentConfiguration
            documentDomainLocked = snapshot.documentDomainLocked
            radialGeometryLocked = snapshot.radialGeometryLocked
            var bytes = Data()
            switch snapshot.storage {
            case let .singleRaster(pixels):
                bytes.append(contentsOf: pixels)
            case let .radialPages(pages):
                for page in pages.sorted(by: {
                    $0.coordinate < $1.coordinate
                }) {
                    bytes.append(
                        contentsOf:
                        "\(page.coordinate.x),\(page.coordinate.y)\0".utf8
                    )
                    bytes.append(contentsOf: page.bgra8PremultipliedBytes)
                }
            }
            storageHash = BrushContentHash.sha256Hex(of: bytes)
        }
    }

    private struct CompletedProfessionalReplaySnapshot: Equatable {
        let generationID: String
        let cardID: String
        let canvasHash: String
        let traceHash: String
        let substrateInputCount: Int
        let snapshot: ProfessionalReviewDocumentSnapshot
        let packageHash: String
        let definitionID: String
        let semanticHash: String
        let pipelineKey: String
        let abiVersion: UInt16
        let diagnostics: BrushLabDiagnostics
        let professionalPasses: [BrushLabProfessionalPassReplay]

        init?(_ replay: BrushLabCompletedReplay?) {
            guard let replay else { return nil }
            generationID = replay.generationID
            cardID = replay.cardID
            canvasHash = replay.canvasHash
            traceHash = replay.traceHash
            substrateInputCount = replay.substrateInputCount
            snapshot = .init(replay.snapshot)
            packageHash = replay.packageHash
            definitionID = replay.definitionID
            semanticHash = replay.semanticHash
            pipelineKey = replay.pipelineKey
            abiVersion = replay.abiVersion
            diagnostics = replay.diagnostics
            professionalPasses = replay.professionalPasses
        }
    }

    private struct ProfessionalReviewStateSnapshot: Equatable {
        let reviewMatrix: BrushLabReviewMatrix
        let selectedManualCardID: String?
        let selectedProfessionalManualCardID: String?
        let completedReplay: CompletedProfessionalReplaySnapshot?
        let packageDefinitionID: String?
        let sourceName: String?
        let packageContentHash: String?
        let activeDrawingPackageContentHash: String?
        let compiledIdentity: BrushRenderIdentity?
        let compilationReport: BrushCompilationReport?
        let compilationFailure: BrushCompilationFailure?
        let compilationDiagnostics: [String]
        let drawingAvailability: BrushLabDrawingAvailability
        let inputRecords: [BrushLabInputRecord]
        let dabRecords: [BrushLabDabRecord]
        let droppedInputRecordCount: Int
        let droppedDabRecordCount: Int
        let professionalPassRecords: [BrushLabProfessionalPassReplay]
        let currentProfessionalPassIndex: Int?
        let nextProfessionalPassIndex: Int
        let professionalDrawIdentity: BrushRenderIdentity?
        let professionalEraserIdentity: BrushRenderIdentity?
        let activeProfessionalIdentity: BrushRenderIdentity?
        let frameMetrics: BrushLabFrameMetrics
        let isLoading: Bool
        let errorMessage: String?
        let compilerDiagnostics: BrushCompilerDiagnosticSnapshot
        let compilerCachedKeys: [String]
        let compilerPinnedKeys: [String]
        let compilerResidentBytes: Int
        let compilerActiveIdentity: BrushRenderIdentity?
        let rendererDrawIdentity: BrushRenderIdentity?
        let rendererEraserIdentity: BrushRenderIdentity?
        let document: ProfessionalReviewDocumentSnapshot
        let modelDocumentConfiguration: SymmetryDocumentConfiguration
        let modelPixelSize: PixelSize
        let modelTool: EditorTool
        let modelInkColor: InkColor
        let modelBrushDiameter: Float
        let modelSelectedRecipeID: BrushRecipeID
        let modelCanUndo: Bool
        let modelCanRedo: Bool
        let transactionState: EditorTransactionState
    }

    private func professionalReviewSnapshot(
        _ runtime: (
            controller: EditorSessionController,
            session: BrushLabSession
        )
    ) throws -> ProfessionalReviewStateSnapshot {
        ProfessionalReviewStateSnapshot(
            reviewMatrix: runtime.session.reviewMatrix,
            selectedManualCardID: runtime.session.selectedManualCardID,
            selectedProfessionalManualCardID:
                runtime.session.selectedProfessionalManualCardID,
            completedReplay: .init(runtime.session.completedReplay),
            packageDefinitionID: runtime.session.package?.definition.id.rawValue,
            sourceName: runtime.session.sourceName,
            packageContentHash: runtime.session.packageContentHash,
            activeDrawingPackageContentHash:
                runtime.session.activeDrawingPackageContentHash,
            compiledIdentity:
                runtime.session.compiledBrush?.renderIdentity,
            compilationReport: runtime.session.compilationReport,
            compilationFailure: runtime.session.compilationFailure,
            compilationDiagnostics:
                runtime.session.compilationDiagnostics,
            drawingAvailability: runtime.session.drawingAvailability,
            inputRecords: runtime.session.inputRecords,
            dabRecords: runtime.session.dabRecords,
            droppedInputRecordCount:
                runtime.session.droppedInputRecordCount,
            droppedDabRecordCount:
                runtime.session.droppedDabRecordCount,
            professionalPassRecords:
                runtime.session.professionalPassRecords,
            currentProfessionalPassIndex:
                runtime.session.currentProfessionalPassIndex,
            nextProfessionalPassIndex:
                runtime.session.nextProfessionalPassIndex,
            professionalDrawIdentity:
                runtime.session.professionalDrawBrush?.renderIdentity,
            professionalEraserIdentity:
                runtime.session.professionalEraserBrush?.renderIdentity,
            activeProfessionalIdentity:
                runtime.session.activeProfessionalCompiledBrush?
                    .renderIdentity,
            frameMetrics: runtime.session.frameMetrics,
            isLoading: runtime.session.isLoading,
            errorMessage: runtime.session.errorMessage,
            compilerDiagnostics:
                runtime.session.compiler.diagnosticSnapshot,
            compilerCachedKeys: runtime.session.compiler.cachedKeys,
            compilerPinnedKeys: runtime.session.compiler.pinnedKeys,
            compilerResidentBytes:
                runtime.session.compiler.residentByteCount,
            compilerActiveIdentity:
                runtime.session.compiler.activeBrush?.renderIdentity,
            rendererDrawIdentity:
                runtime.controller.renderer.preparedBrush(for: .draw)?
                    .renderIdentity,
            rendererEraserIdentity:
                runtime.controller.renderer.preparedBrush(for: .erase)?
                    .renderIdentity,
            document: .init(
                try runtime.controller.renderer.captureCommittedDocument()
            ),
            modelDocumentConfiguration:
                runtime.controller.model.documentConfiguration,
            modelPixelSize: runtime.controller.model.pixelSize,
            modelTool: runtime.controller.model.tool,
            modelInkColor: runtime.controller.model.inkColor,
            modelBrushDiameter: runtime.controller.model.brushDiameter,
            modelSelectedRecipeID:
                runtime.controller.model.selectedRecipeID,
            modelCanUndo: runtime.controller.model.canUndo,
            modelCanRedo: runtime.controller.model.canRedo,
            transactionState:
                runtime.controller.transactionStateForTesting
        )
    }

    private func mutateProfessionalDocument(
        in object: inout [String: Any],
        cardIndex: Int,
        _ mutate: (inout [String: Any]) -> Void
    ) {
        var cards = object["cards"] as! [[String: Any]]
        var document =
            cards[cardIndex]["documentConfiguration"] as! [String: Any]
        mutate(&document)
        cards[cardIndex]["documentConfiguration"] = document
        object["cards"] = cards
    }

    private func mutateProfessionalStroke(
        in object: inout [String: Any],
        cardIndex: Int,
        passIndex: Int = 0,
        strokeIndex: Int = 0,
        _ mutate: (inout [String: Any]) -> Void
    ) {
        var cards = object["cards"] as! [[String: Any]]
        var passes = cards[cardIndex]["passes"] as! [[String: Any]]
        var strokes = passes[passIndex]["strokes"] as! [[String: Any]]
        mutate(&strokes[strokeIndex])
        passes[passIndex]["strokes"] = strokes
        cards[cardIndex]["passes"] = passes
        object["cards"] = cards
    }

    private func mutateProfessionalSample(
        in object: inout [String: Any],
        cardIndex: Int,
        passIndex: Int = 0,
        strokeIndex: Int = 0,
        sampleIndex: Int,
        _ mutate: (inout [String: Any]) -> Void
    ) {
        mutateProfessionalStroke(
            in: &object,
            cardIndex: cardIndex,
            passIndex: passIndex,
            strokeIndex: strokeIndex
        ) {
            var samples = $0["samples"] as! [[String: Any]]
            mutate(&samples[sampleIndex])
            $0["samples"] = samples
        }
    }

    private func expectProfessionalSemanticFailure(
        _ object: [String: Any],
        gesture: String,
        mutation: String,
        expectedError: String
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        do {
            try ProfessionalManualEvidenceValidator.validateSemantics(data)
            Issue.record(
                "Semantic boundary accepted \(gesture) \(mutation)"
            )
        } catch {
            #expect(
                error.localizedDescription == expectedError,
                "\(gesture) \(mutation): \(error.localizedDescription)"
            )
        }
        do {
            _ = try ProfessionalManualEvidenceValidator.validate(data)
            Issue.record("Accepted \(gesture) \(mutation)")
        } catch {
            #expect(
                error.localizedDescription == expectedError,
                "\(gesture) \(mutation) digest: \(error.localizedDescription)"
            )
        }
    }

    private func makeRuntime(
        forceClearFailure: (() -> Bool)? = nil,
        brushCacheBudgetBytes: Int = 128 * 1_024 * 1_024,
        compilerHooks: BrushCompilerTestHooks = .none
    ) throws -> (
        controller: EditorSessionController,
        session: BrushLabSession
    )? {
        guard let renderer = try makeControllerRenderer(),
              let queue = renderer.device.makeCommandQueue()
        else {
            return nil
        }
        let controller: EditorSessionController
        if let forceClearFailure {
            controller = EditorSessionController(
                renderer: renderer,
                requestClear: { token, maximumRetainedBytes in
                    try renderer.requestClearForHarness(
                        token: token,
                        maximumRetainedBytes: maximumRetainedBytes,
                        forceFailure: forceClearFailure()
                    )
                }
            )
        } else {
            controller = EditorSessionController(renderer: renderer)
        }
        let profile = try BrushDeviceProfile(
            registryID: renderer.device.registryID,
            recommendedWorkingSetBytes: 1_024 * 1_024 * 1_024,
            maximumWorkingTextureDimension: 4_096,
            brushCacheBudgetBytes: brushCacheBudgetBytes,
            targetFramesPerSecond: 120
        )
        let pipelineLibrary = try makeNativeDepositionPipelineLibrary(
            device: renderer.device
        )
        let compiler = BrushCompiler(
            device: renderer.device,
            commandQueue: queue,
            profile: profile,
            pipelinePreparing: pipelineLibrary,
            testHooks: compilerHooks
        )
        return (
            controller,
            BrushLabSession(controller: controller, compiler: compiler)
        )
    }

    @MainActor
    private final class ProfessionalCompilationGate {
        private let definitionID: String
        private var hasPaused = false
        private var pauseContinuation: CheckedContinuation<Void, Never>?
        private var arrivalContinuation: CheckedContinuation<Void, Never>?

        init(definitionID: String) {
            self.definitionID = definitionID
        }

        func pauseFirstMatching(
            _ context: BrushCompilerPhaseContext
        ) async {
            guard !hasPaused,
                  context.phase == .beforeDecode,
                  context.definitionID == definitionID
            else {
                return
            }
            hasPaused = true
            arrivalContinuation?.resume()
            arrivalContinuation = nil
            await withCheckedContinuation {
                pauseContinuation = $0
            }
        }

        func waitUntilPaused() async {
            guard !hasPaused else { return }
            await withCheckedContinuation {
                arrivalContinuation = $0
            }
        }

        func resume() {
            pauseContinuation?.resume()
            pauseContinuation = nil
        }
    }

    private func expectStaleDocumentMutationRejected(
        _ card: BrushLabManualCard,
        key: String,
        value: Any
    ) throws {
        let data = try JSONEncoder().encode(card)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var document = try #require(
            object["documentConfiguration"] as? [String: Any]
        )
        document[key] = value
        object["documentConfiguration"] = document
        let mutated = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self, "Accepted stale \(key)") {
            _ = try JSONDecoder().decode(
                BrushLabManualCard.self,
                from: mutated
            )
        }
    }

    private func singleRasterBytes(
        _ snapshot: CommittedDocumentSnapshot
    ) -> [UInt8]? {
        guard case let .singleRaster(bytes) = snapshot.storage else {
            return nil
        }
        return bytes
    }

    private func alphaSum(_ pixels: [UInt8]) -> UInt64 {
        stride(from: 3, to: pixels.count, by: 4).reduce(0) {
            $0 + UInt64(pixels[$1])
        }
    }

    private func makePackage(
        nativeOnly: Bool = false,
        wet: Bool = false
    ) throws
        -> BrushPackage
    {
        let base = try LegacyBrushRecipeAdapter.definition(
            from: BrushRecipe(id: BrushRecipeID("brush-lab.fixture")),
            displayName: "Brush Lab Fixture"
        )
        let definition: BrushDefinition
        if nativeOnly || wet {
            let material = wet ? BrushMaterialDefinition(
                accumulation: base.material.accumulation,
                interaction: .wetMix,
                edgeTreatment: base.material.edgeTreatment,
                strength: base.material.strength,
                wetness: base.material.wetness,
                bleedRadius: base.material.bleedRadius,
                softenPasses: base.material.softenPasses,
                accumulationLimit: base.material.accumulationLimit,
                interactionParameters: BrushInteractionDefinition(
                    pickup: 0.2, pull: 0.4, dilution: 0.3, charge: 0.4,
                    persistence: 0.5, dirtyHaloRadius: 2
                )
            ) : base.material
            definition = try BrushDefinition(
                id: base.id,
                schemaVersion: base.schemaVersion,
                metadata: base.metadata,
                capabilities: wet ? [BrushCapabilityDeclaration(
                    identifier: BrushCapability.wetMix.rawValue,
                    required: true
                )] : base.capabilities,
                resources: base.resources,
                coverage: base.coverage,
                placement: base.placement,
                dynamics: base.dynamics,
                color: base.color,
                material: material,
                stabilization: base.stabilization,
                taper: base.taper,
                replayMode: base.replayMode,
                replayLimits: base.replayLimits,
                seedPolicy: base.seedPolicy,
                limits: base.limits,
                performanceIntent: .quality,
                compatibility: base.compatibility
            )
        } else {
            definition = base
        }
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: []),
            definition: definition,
            resourceData: [:]
        )
    }

    private func makeCorruptResourcePackage() throws -> BrushPackage {
        let resourceID = "brush-lab.corrupt.shape"
        let data = Data([1, 2, 3, 4])
        let resource = try BrushPackageResource(
            id: resourceID,
            kind: .shape,
            mediaType: "image/png",
            data: data,
            pixelWidth: 4,
            pixelHeight: 4
        )
        let base = AnchorBrushCatalog.ink.definition
        let definition = try BrushDefinition(
            id: BrushRecipeID("brush-lab.corrupt"),
            schemaVersion: base.schemaVersion,
            metadata: base.metadata,
            capabilities: base.capabilities,
            resources: [
                BrushResourceReference(
                    identifier: resourceID,
                    kind: .shape,
                    required: true,
                    fallback: nil
                ),
            ],
            coverage: BrushCoverageDefinition(
                shapes: [
                    BrushShapeLayerDefinition(
                        shape: .asset(resourceID),
                        combination: .replace,
                        scale: 1,
                        rotation: 0,
                        offset: .zero
                    ),
                ],
                grains: [],
                baseHardness: base.coverage.baseHardness,
                aspectRatio: base.coverage.aspectRatio,
                tipThreshold: base.coverage.tipThreshold,
                antialiasing: base.coverage.antialiasing
            ),
            placement: base.placement,
            dynamics: base.dynamics,
            color: base.color,
            material: base.material,
            stabilization: base.stabilization,
            taper: base.taper,
            replayMode: base.replayMode,
            replayLimits: base.replayLimits,
            seedPolicy: base.seedPolicy,
            limits: base.limits,
            performanceIntent: base.performanceIntent,
            compatibility: base.compatibility
        )
        return try BrushPackage(
            manifest: BrushPackageManifest(resources: [resource]),
            definition: definition,
            resourceData: [resourceID: data]
        )
    }

    private func rendererProgram(
        _ controller: EditorSessionController
    ) -> BrushProgram? {
        controller.renderer.harnessActiveStrokeStyle?.program
    }
}

@MainActor
final class BrushLabTestPipelinePreparer:
    DepositionPipelinePreparing
{
    private let state: any MTLRenderPipelineState
    private var bindings:
        [DepositionPipelineKey: DepositionPipelineBinding] = [:]

    init(device: any MTLDevice) throws {
        state = try makeBrushLabTestPipelineState(device: device)
    }

    func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding {
        if let binding = bindings[key] {
            return binding
        }
        let binding = DepositionPipelineBinding(key: key, state: state)
        bindings[key] = binding
        return binding
    }
}

@MainActor
func makeBrushLabTestPipelineState(
    device: any MTLDevice
) throws -> any MTLRenderPipelineState {
    let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 brushLabCompilerVertex(uint id [[vertex_id]]) {
            const float2 points[3] = {
                float2(-1, -1), float2(3, -1), float2(-1, 3)
            };
            return float4(points[id], 0, 1);
        }
        fragment float4 brushLabCompilerFragment() {
            return float4(0);
        }
        """
    let library = try device.makeLibrary(source: source, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(
        name: "brushLabCompilerVertex"
    )
    descriptor.fragmentFunction = library.makeFunction(
        name: "brushLabCompilerFragment"
    )
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    return try device.makeRenderPipelineState(descriptor: descriptor)
}
#endif
