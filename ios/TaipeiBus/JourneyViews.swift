import SwiftUI
import MapKit
import TransitCore

struct JourneyPlanningView: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    @ObservedObject var location: LocationService
    @Binding var showingItinerary: Bool
    let compact: Bool
    let expand: () -> Void
    let collapse: () -> Void
    @StateObject private var search = PlaceSearch()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var editingOrigin = false
    @State private var editingDestination: Bool
    @State private var resolving = false
    @State private var searchError: String?
    @State private var resolveTask: Task<Void, Never>?
    @State private var resolveToken = UUID()
    @State private var resolvingQuery = ""
    @State private var stationResults: [Station] = []
    @State private var stationResultQuery = ""
    @State private var showingRankingInfo = false
    @State private var searchReturnToItinerary = false
    @State private var showingPro = false
    @State private var showingSaveJourney = false
    @State private var showingTripPreference = false
    @ObservedObject private var assistant: JourneyAssistantSession
    @ObservedObject private var assistantRecents = AssistantRecents.shared
    @State private var assistantAvailable = OnDeviceJourneyAssistant.plannerUnavailableReason() == nil
    @Environment(\.scenePhase) private var scenePhase

    init(model: TransitAppModel, planner: JourneyPlannerModel, location: LocationService, showingItinerary: Binding<Bool>,
         compact: Bool, expand: @escaping () -> Void, collapse: @escaping () -> Void) {
        self.model = model; self.planner = planner; self.location = location; assistant = model.assistant
        _showingItinerary = showingItinerary
        self.compact = compact; self.expand = expand; self.collapse = collapse
        // Start on the page the sheet will actually show. Starting on place search and flipping
        // in onAppear animated a squeezed search page into every itinerary opening.
        _editingDestination = State(initialValue: planner.destination == nil)
    }

    private var searchingPlaces: Bool { editingOrigin || editingDestination }
    private var scale: CGFloat { CGFloat(live.appearance.spacingScale) }
    private var fieldShape: RoundedRectangle { RoundedRectangle(cornerRadius: Metrics.fieldRadius * CGFloat(live.appearance.cornerScale), style: .continuous) }
    /// A titled group in search results; it lines up with the text inside the fields above.
    private func sectionHeader(_ text: String) -> some View {
        Text(text).liveFont(.footnote, weight: .semibold).foregroundStyle(MapChrome.secondaryText)
            .padding(.top, (Metrics.section - Metrics.gap) * scale).padding(.horizontal, Metrics.inset)
    }
    private var searchContext: Coordinate? {
        planner.usingLocation ? location.usableCoordinate ?? location.displayCoordinate : planner.origin?.coordinate
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: (searchingPlaces || compact ? Metrics.gap : Metrics.margin) * scale) {
                    if searchingPlaces { originButton }
                    else if !planner.started && !showingItinerary { routeEndpoints }
                    AssistantInlineStatus(session: assistant)
                    if searchingPlaces { placeSearch }
                    else {
                        if planner.started || showingItinerary {
                            JourneyItineraryView(model: model, planner: planner, showMap: {
                                if planner.started { dismiss() }
                                else { showingItinerary = false; collapse() }
                            })
                        } else {
                            if planner.destination != nil { TripConditionsBar(model: model, planner: planner, session: assistant) }
                            JourneyOptionsView(model: model, planner: planner, collapse: {
                                showingItinerary = false; collapse()
                            }, compact: compact, expand: expand, showSteps: {
                                showingItinerary = true; expand()
                            }, go: { option in
                                // Apple Maps' Go: start the shown option straight from its card.
                                planner.select(option); planner.begin()
                                guard planner.started else { return }
                                if case .walk(let index) = planner.currentStep { model.showWalkOnMap(index) }
                                dismiss()
                            })
                        }
                    }
                }.padding(.horizontal, 16 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 12 * CGFloat(live.appearance.spacingScale))
                    .smoothChanges(searchingPlaces)
                    .smoothChanges(showingItinerary)
                    .smoothChanges(model.language)
                    .id("journey-scroll-top")
            }
            .onChange(of: showingItinerary) { _, showing in
                guard showing, !planner.started else { return }
                DispatchQueue.main.async {
                    guard showingItinerary, !planner.started else { return }
                    // The route card may have been scrolled to Go. Details begin at their
                    // destination and total, rather than inheriting that preview offset.
                    scroll.scrollTo("journey-scroll-top", anchor: .top)
                }
            }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if !searchingPlaces, showingItinerary, !planner.started, planner.selected != nil, planner.scheduledDeparture == nil {
                    Button {
                        planner.begin()
                        guard planner.started else { return }
                        if case .walk(let index) = planner.currentStep { model.showWalkOnMap(index) }
                        dismiss()
                    } label: {
                        Label(AppText.text("開始導航"), systemImage: "location.fill")
                            .liveFont(.body, weight: .bold).frame(maxWidth: .infinity, minHeight: 52)
                    }.buttonStyle(MapActionStyle(prominent: true, tint: MapChrome.go)).accessibilityIdentifier("journey-start-navigation")
                        .disabled(planner.selected.map { !planner.canUse($0) } ?? true)
                        .padding(.horizontal, 20).padding(.vertical, 10).background(.regularMaterial)
                }
            }
            .navigationTitle(editingOrigin ? AppText.text("出發地") : searchingPlaces ? AppText.text("目的地") : planner.started || showingItinerary ? AppText.text("行程") : AppText.text("路線"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !searchingPlaces, !showingItinerary, !planner.started, model.activeRoutePreference != .balanced {
                    ToolbarItem(placement: .principal) {
                        Button { showingTripPreference = true } label: {
                            VStack(spacing: 1) {
                                Text(AppText.text("路線")).font(.headline).foregroundStyle(.primary)
                                HStack(spacing: 3) {
                                    Text(model.activeRoutePreference.title)
                                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                                }.font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                            }.frame(minWidth: 80, minHeight: 44)
                        }.buttonStyle(.plain).accessibilityIdentifier("journey-active-preference")
                    }
                }
                if searchingPlaces || showingItinerary || planner.started {
                ToolbarItem(placement: .cancellationAction) {
                    Button(live.text(searchingPlaces ? "取消" : showingItinerary && !planner.started ? "返回路線" : "返回地圖")) {
                        if showingItinerary && !planner.started && !searchingPlaces {
                            model.clearWalkingMap(); showingItinerary = false; collapse()
                            model.focusMap(.journey(planner.mapCoordinates))
                        } else if searchingPlaces, planner.destination != nil {
                            focused = false; resolveTask?.cancel(); search.cancel()
                            resolving = false; editingOrigin = false; editingDestination = false
                            showingItinerary = searchReturnToItinerary; searchReturnToItinerary = false
                            if !planner.started { if showingItinerary { expand() } else { collapse() } }
                        } else { dismiss() }
                    }.accessibilityIdentifier("journey-back")
                }
                }
                if !searchingPlaces {
                    ToolbarItem(placement: .confirmationAction) {
                        if planner.started {
                            Button(live.text("更改")) { edit(origin: false) }
                        } else {
                            Button { model.finishJourney(); dismiss() } label: {
                                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.primary).frame(width: 36, height: 36)
                            }.accessibilityLabel(AppText.text("關閉路線"))
                                .accessibilityIdentifier("journey-close")
                        }
                    }
                    if !planner.started, !showingItinerary {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                Button(live.text("查看行程")) { showingItinerary = true; expand() }
                                Button(AppText.text("重新比較路線")) { planner.refreshRecommendations() }
                                Button(AppText.text("推薦順序說明")) { showingRankingInfo = true }
                                Button(AppText.text("儲存行程")) {
                                    if model.purchases.hasPro { showingSaveJourney = true } else { showingPro = true }
                                }.accessibilityIdentifier("journey-save-pro")
                                Button(AppText.text("個人路線偏好")) {
                                    if model.purchases.hasPro { showingTripPreference = true } else { showingPro = true }
                                }.accessibilityIdentifier("journey-preference-pro")
                                Button(live.text("其他交通方式")) { planner.openAppleTransit() }
                            } label: { Image(systemName: "ellipsis").foregroundStyle(.primary).frame(width: 36, height: 36) }
                                .accessibilityLabel(live.text("更多行程選項"))
                                .accessibilityIdentifier("journey-plan-more")
                        }
                    }
                }
            }
        }
        .alert(AppText.text("推薦順序"), isPresented: $showingRankingInfo) {
            Button(AppText.text("知道了"), role: .cancel) {}
        } message: {
            Text(AppText.text("先確認實際步行，再比較可趕上的班次、候車與搭車時間。推薦兼顧時間、少走路與少轉乘；較快方案會另外保留。班距推估會標示範圍，班次不足則標示待確認。抵達時間包含走路、候車與搭車。"))
        }
        .sheet(isPresented:$showingPro) { ProPurchaseView(purchases:model.purchases) }
        .sheet(isPresented:$showingSaveJourney) { SaveJourneyView(model:model) }
        .sheet(isPresented:$showingTripPreference) { TripPreferenceView(model:model) }
        .modifier(OnlineConsentAlert(session: assistant, inSheet: false))
        .sheet(isPresented: $assistant.presented, onDismiss: { assistant.dismissed() }) {
            AIJourneyAssistantView(session: assistant, model: model)
        }
        // A request reached the route screen: show its routes.
        .onChange(of: assistant.plannedCount) { _, _ in
            focused = false; query = ""; editingOrigin = false; editingDestination = false; showingItinerary = false; collapse()
        }
        .bikeStationDetails(model: model)
        // The typing sheet listens in place; everywhere else speaking opens the voice screen.
        .modifier(VoiceAssistantPresenter(session: assistant, enabled: !assistant.presented))
        .onChange(of: model.pendingAssistantRequest, initial: true) { _, text in
            guard let text, assistantAvailable else { return }
            model.pendingAssistantRequest = nil
            openAssistant(text)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { assistantAvailable = OnDeviceJourneyAssistant.plannerUnavailableReason() == nil }
        }
        .onChange(of: AppLanguage.current) { _, _ in
            assistantAvailable = OnDeviceJourneyAssistant.plannerUnavailableReason() == nil
        }
        .onAppear {
            assistantAvailable = OnDeviceJourneyAssistant.plannerUnavailableReason() == nil
            search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
            search.setContext(searchContext)
            editingDestination = planner.destination == nil
            if planner.origin == nil && planner.usingLocation {
                planner.useLocation(location.usableCoordinate, metadata: model.metadata)
                if location.usableCoordinate == nil { location.request() }
            }
            focused = editingDestination
            // The voice screen started on the map and needs the sheet: open it once this panel is up.
            if assistant.reopenSheetInPanel {
                assistant.reopenSheetInPanel = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { assistant.presented = true }
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-journey-search") {
                focused = false
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "--preview-search-query"), arguments.indices.contains(index + 1) { query = arguments[index + 1] }
                else { query = "臺北車站" }
            }
#endif
        }
        .onChange(of: query) { _, value in
            if resolving && value != resolvingQuery {
                resolveTask?.cancel(); resolveToken = UUID(); resolving = false; search.cancel()
            }
            searchError = nil; search.update(value)
        }
        .onChange(of: planner.options.count) { _, count in
            if count > 0, !searchingPlaces, !planner.started, !showingItinerary { focused = false }
        }
        .onChange(of: location.revision) { _, _ in search.setContext(searchContext) }
        .onChange(of: model.liveSettings.revision) { _, _ in
            search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
        }
        .onDisappear { resolveTask?.cancel(); search.cancel() }
        .task(id: query + ":" + model.stationSearchContextKey) {
            let text = query
            let matches = await model.findStations(query: text, limit: text.isEmpty ? 3 : model.liveSettings.search.resultLimit)
            guard !Task.isCancelled else { return }
            stationResults = matches; stationResultQuery = text
            search.setStationHints(matches)
        }
    }
    private var routeEndpoints: some View {
        VStack(spacing: 0) {
            Button { edit(origin: true) } label: {
                HStack(spacing: 12) {
                    Image(systemName: planner.usingLocation ? "location.circle.fill" : "mappin.circle.fill")
                        .foregroundStyle(.blue).liveFont(.title2).frame(width: Metrics.icon)
                    Text(planner.origin?.localizedName ?? AppText.text("選擇出發地"))
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down").liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                }.frame(minHeight: 48).contentShape(Rectangle())
            }.accessibilityIdentifier("journey-edit-origin")
            Divider().padding(.leading, Metrics.icon + 12)
            Button { edit(origin: false) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.red).liveFont(.title2).frame(width: Metrics.icon)
                    Text(planner.destination?.localizedName ?? AppText.text("目的地"))
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down").liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                }.frame(minHeight: 48).contentShape(Rectangle())
            }.accessibilityIdentifier("journey-edit-destination")
        }.liveFont(.subheadline, weight: .medium).foregroundStyle(.primary).buttonStyle(PhonePressStyle())
            .padding(.horizontal, Metrics.inset).padding(.vertical, 2)
            .background(Color(uiColor: .tertiarySystemFill), in: fieldShape)
    }
    /// The start, shaped and aligned exactly like the search field below it.
    private var originButton: some View {
        HStack(spacing: 0) {
            Button { edit(origin: true) } label: {
                HStack(spacing: 12) {
                    Image(systemName: planner.usingLocation ? "location.fill" : "circle.fill")
                        .foregroundStyle(Color(liveHex: live.appearance.accentColor)).frame(width: Metrics.icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(planner.origin?.localizedName ?? (location.requesting ? AppText.text("取得位置中") : AppText.text("選擇出發地")))
                            .liveFont(.subheadline, weight: .semibold).lineLimit(1)
                        if planner.origin == nil {
                            Text(location.message.map(live.text) ?? AppText.text("可使用定位，或輸入出發地／站名")).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").liveFont(.caption, weight: .semibold).foregroundStyle(MapChrome.secondaryText)
                }
                .padding(.leading, Metrics.inset).padding(.trailing, planner.usingLocation ? Metrics.inset : Metrics.tight)
                .frame(minHeight: Metrics.field).contentShape(Rectangle())
            }.buttonStyle(PhonePressStyle())
            // Only offered when the start is somewhere else; with 目前位置 it would repeat itself.
            if !planner.usingLocation {
                Divider().frame(height: 24)
                Button {
                    planner.useLocation(location.usableCoordinate, metadata: model.metadata); location.request()
                    editingOrigin = false; editingDestination = planner.destination == nil; query = ""
                } label: { Image(systemName: "location.circle").liveFont(.title3).frame(width: 48, height: Metrics.field) }
                    .accessibilityLabel(live.text("使用目前位置出發"))
            }
        }
        .background(Color(uiColor: .tertiarySystemFill), in: fieldShape)
    }
    /// A sentence such as 「騎單車去台大」 typed in the ordinary search box is understood, not searched.
    private var understandsSentence: Bool { speaksSentence && AssistantSentence.looksLikeRequest(query) }
    /// The search box plans a sentence, said into its microphone or typed.
    private var speaksSentence: Bool {
        assistantAvailable && model.liveSettings.display.sentencePlanning && !editingOrigin && !planner.started
    }
    /// A sentence is understood right here; only a question or a problem opens the sheet.
    private func openAssistant(_ text: String?) {
        focused = false
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { assistant.run(text) } else { assistant.open() }
    }
    private var placeSearch: some View {
        VStack(alignment: .leading, spacing: Metrics.gap * scale) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(MapChrome.secondaryText).frame(width: Metrics.icon)
                TextField(editingOrigin ? AppText.text("出發地、地址或站名")
                          : assistantAvailable && !planner.started ? AppText.text("地點，或一句話：騎單車去台大") : AppText.text("地點、地址或站名"), text: $query)
                    .accessibilityIdentifier("journey-search-field")
                    .focused($focused).submitLabel(.search).autocorrectionDisabled()
                    .onSubmit { understandsSentence ? openAssistant(query) : resolve(text: query) }
                if resolving || search.searching { ProgressView() }
                else if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MapChrome.secondaryText) } }
                else if speaksSentence {
                    // Say where to go, as in any search box: the sentence is planned right here.
                    Button { focused = false; assistant.listen(inline: true) } label: {
                        Image(systemName: "mic.fill").foregroundStyle(MapChrome.secondaryText).frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderless).disabled(assistant.busy)
                    .accessibilityLabel(AppText.text("用說的搜尋")).accessibilityIdentifier("journey-search-voice")
                }
            }.padding(.horizontal, Metrics.inset).frame(minHeight: Metrics.field)
                .background(Color(uiColor: .tertiarySystemFill), in: fieldShape)
            if let error = searchError ?? search.error { Text(live.text(error)).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText) }
            // One clear action for what was typed: plan the sentence, or search the place.
            if understandsSentence, !assistant.busy {
                Button { openAssistant(query) } label: {
                    Label(AppText.text("規劃「%@」", query), systemImage: "sparkles").liveFont(.subheadline, weight: .semibold)
                        .lineLimit(2).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("journey-understand-sentence")
                Button(AppText.text("只搜尋地點")) { resolve(text: query) }
                    .font(.footnote).foregroundStyle(MapChrome.secondaryText).disabled(resolving)
            } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { resolve(text: query) } label: {
                    Label(AppText.text("搜尋「%@」", query), systemImage: "arrow.up.right").liveFont(.subheadline, weight: .semibold).frame(minHeight: 44)
                }.secondaryAction().disabled(resolving)
            }
            if query.isEmpty {
                if !editingOrigin, !planner.started, VoiceConversation.available {
                    // The voice assistant: talk it through, ask about buses, fares or a place (Pro).
                    VoiceStartCard { focused = false; model.voiceChat.start() }
                }
                if speaksSentence, !assistantRecents.items.isEmpty {
                    // Zero typing: one row of what was said before.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Metrics.tight) {
                            ForEach(assistantRecents.items.prefix(6), id: \.self) { text in
                                Button { openAssistant(text) } label: {
                                    Label(text, systemImage: "clock.arrow.circlepath").font(.subheadline).lineLimit(1)
                                        .padding(.horizontal, 12).frame(minHeight: Metrics.chip)
                                        .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("journey-recent-request")
                                    .contextMenu { Button(AppText.text("從最近說過移除"), role: .destructive) { assistantRecents.remove(text) } }
                            }
                        }
                    }
                    // Scrolls to the panel's edges instead of being cut off at its margin.
                    .contentMargins(.horizontal, Metrics.margin * scale, for: .scrollContent)
                    .padding(.horizontal, -Metrics.margin * scale)
                }
                if !editingOrigin, !planner.started {
                    CommuteHabitSuggestions(habits: model.commuteHabits, library: model.commutes) { saved in
                        model.previewSavedJourney(saved)
                        focused = false; editingDestination = false; showingItinerary = false; collapse()
                    }
                    JourneySavedShortcuts(model: model) { saved in
                        model.previewSavedJourney(saved)
                        focused = false; editingDestination = false; showingItinerary = false; collapse()
                    }
                }
                if !editingOrigin && !planner.recentPlaces.isEmpty {
                    sectionHeader(live.text("最近目的地"))
                    ForEach(planner.recentPlaces) { place in
                        placeButton(place, symbol: "clock")
                            .contextMenu { Button(AppText.text("從最近目的地移除"), role: .destructive) { planner.removeRecentPlace(place.id) } }
                    }
                }
                if !editingOrigin && live.display.quickDestinations {
                    JourneyChainLayout(spacing: 8) {
                        ForEach(live.quickDestinations, id: \.self) { name in
                            Button(name) { query = name; resolve(text: name) }.liveFont(.subheadline)
                                .padding(.horizontal, 12 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 44)
                                .background(Color(liveHex: live.appearance.accentColor).opacity(0.08), in: Capsule())
                        }
                    }.padding(.top, 8 * CGFloat(live.appearance.spacingScale))
                }
            }
            if !search.places.isEmpty {
                sectionHeader(live.text("地點搜尋結果"))
                ForEach(search.places) { place in placeButton(place, symbol: "mappin.circle.fill") }
            }
            if !search.suggestions.isEmpty && search.places.isEmpty { sectionHeader(live.text("地點")) }
            ForEach(Array((search.places.isEmpty ? Array(search.suggestions.prefix(6)) : []).enumerated()), id: \.offset) { _, completion in
                Button { resolve(text: completion.title, completion: completion) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle").liveFont(.title2).foregroundStyle(Color(liveHex: live.appearance.accentColor)).frame(width: Metrics.icon)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(completion.title).liveFont(.body, weight: .medium)
                            Text(completion.subtitle).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0); Image(systemName: "arrow.up.left").liveFont(.caption).foregroundStyle(.tertiary)
                    }.padding(.horizontal, Metrics.inset).frame(maxWidth: .infinity, minHeight: Metrics.row, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(resolving)
                Divider().padding(.leading, Metrics.inset + Metrics.icon + 12)
            }
            let stations = stationResultQuery == query ? stationResults : []
            if !stations.isEmpty { sectionHeader(live.text("車站與站牌")) }
            ForEach(StationSearch.groups(stations)) { group in
                DisclosureGroup {
                ForEach(group.stations) { station in
                    Button {
                        choose(TravelPlace(name: station.name, address: "\(station.localizedBearing) · \(station.address)", coordinate: station.coordinate, englishName: station.englishName))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: station.mode == .bus ? "bus.fill" : "tram.fill").foregroundStyle(Color(liveHex: live.appearance.accentColor)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(station.localizedBearing.isEmpty ? station.localizedName : station.localizedBearing).liveFont(.subheadline, weight: .medium)
                                Text(station.address.isEmpty ? station.localizedName : station.address).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
                        }.frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(resolving)
                }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: group.stations.contains(where: { $0.mode != .bus }) ? "tram.fill" : "bus.fill").foregroundStyle(Color(liveHex: live.appearance.accentColor)).frame(width: 22)
                        BilingualName(chinese: group.name, english: group.localizedName).liveFont(.body, weight: .medium)
                        Spacer(minLength: 4)
                        Text(AppText.text("%@ 處", group.stations.count)).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                    }.frame(minHeight: 44)
                }.padding(.horizontal, Metrics.inset).accessibilityIdentifier("journey-stations-" + group.name)
            }
        }
    }
    private func placeButton(_ place: TravelPlace, symbol: String) -> some View {
        Button { choose(place) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).liveFont(.title3).foregroundStyle(MapChrome.secondaryText).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    BilingualName(chinese: place.name, english: place.englishName ?? AppText.text(place.name)).liveFont(.body, weight: .medium)
                    if !place.address.isEmpty { Text(place.address).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).lineLimit(1) }
                    if !place.coordinate.isInServiceArea { Text(live.text("公車規劃範圍外")).liveFont(.caption).foregroundStyle(MapChrome.secondaryText) }
                }
                Spacer(); Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal, Metrics.inset).frame(minHeight: Metrics.row).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(resolving)
    }
    private func edit(origin: Bool) {
        searchReturnToItinerary = showingItinerary || planner.started
        expand()
        resolveTask?.cancel(); resolveToken = UUID(); search.cancel(); resolving = false
        editingOrigin = origin; editingDestination = !origin; showingItinerary = false; query = ""; searchError = nil; focused = true
        search.setContext(searchContext)
    }
    private func resolve(text: String, completion: MKLocalSearchCompletion? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        resolveTask?.cancel(); resolveToken = UUID(); let token = resolveToken
        resolving = true; resolvingQuery = query; searchError = nil
        resolveTask = Task {
            do {
                var places = try await search.find(text: text, completion: completion)
                guard !Task.isCancelled, token == resolveToken else { return }
                // Nothing found: with online understanding on, ask what the place is officially called.
                if places.isEmpty, completion == nil, OnlineJourneyReader.enabled {
                    for name in await OnlineJourneyReader.rewrite(text, sentence: text, pro: model.purchases.hasPro) {
                        places = (try? await search.find(text: name)) ?? []
                        guard !Task.isCancelled, token == resolveToken else { return }
                        if !places.isEmpty { break }
                    }
                }
                resolving = false
                if completion != nil, let place = places.first { choose(place) }
                else if places.isEmpty { searchError = "找不到相符地點，試試地址或站牌" }
                else { focused = false }
            } catch {
                guard !Task.isCancelled, token == resolveToken else { return }
                resolving = false; searchError = "搜尋暫時無法連線，可改選站牌，或稍後重試。"
            }
        }
    }
    private func choose(_ place: TravelPlace) {
        searchReturnToItinerary = false
        focused = false
        if editingOrigin { planner.setOrigin(place, metadata: model.metadata) }
        else { planner.setDestination(place, metadata: model.metadata, currentLocation: location.usableCoordinate) }
        editingOrigin = false; editingDestination = planner.destination == nil; query = ""
        search.cancel()
        if planner.destination != nil, planner.origin == nil { edit(origin: true) }
        else if planner.destination != nil { collapse() }
    }
}

/// A flat boarding display shared by the sheet and the edge of the map.
struct JourneyBoardingView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            JourneyBoardingContent(model: model, ride: ride, date: timeline.date)
        }
    }
}

private struct JourneyBoardingContent: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    @State private var showTimingInfo = false
    private var guide: BoardingGuide { BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: date) }
    var body: some View {
        if ride.route.mode != .bus {
            MetroBoardingRows(model: model, ride: ride, date: date, showsSource: false)
        } else {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
#if DEBUG
                    model.recordMapTap("show-arrivals")
#endif
                    model.showingArrivingVehicles = true
                } label: {
                    HStack(spacing: 4) {
                        Text(AppText.text("到站車輛"))
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(MapChrome.secondaryText)
                    }.liveFont(.subheadline, weight: .semibold).frame(minHeight: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("journey-all-vehicles")
                Spacer()
                Button { showTimingInfo = true } label: { Image(systemName: "info.circle").liveFont(.subheadline).frame(width: 32, height: 32) }
                    .foregroundStyle(MapChrome.secondaryText)
                    .accessibilityLabel(live.text("到站時間說明"))
                    .popover(isPresented: $showTimingInfo) {
                        Text(live.text("候車以官方下一班到站時間為主。官方未指定車牌；各車紀錄足夠才顯示分鐘數，否則先看位置與站數。地圖平順銜接已收到的定位，保留短暫緩衝。點「到站車輛」可查看時間說明。"))
                            .liveFont(.subheadline).padding(20).frame(maxWidth: 300).presentationCompactAdaptation(.popover)
                    }
            }
            if guide.nextBusWithoutPosition {
                NextBusRow(guide: guide)
                    .background(Color(uiColor: .systemBackground).opacity(0.72), in: live.shape(.row))
            } else if guide.approaches.isEmpty { Text(live.text(guide.emptyPositionLabel)).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText).padding(.vertical, 6 * CGFloat(live.appearance.spacingScale)) }
            else {
                VStack(spacing: 0) {
                    ForEach(Array(guide.approaches.prefix(3))) { approach in
                        BoardingVehicleRow(model: model, ride: ride, approach: approach, date: date)
                        if approach.id != guide.approaches.prefix(3).last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(Color(uiColor: .systemBackground).opacity(0.72), in: live.shape(.row))
            }
            if let bus = model.selectedVehicle, model.metadata.canServe(ride, vehicle: bus),
               !guide.approaches.contains(where: { $0.id == bus.id }) {
                let passed = model.metadata.journey(routeID: bus.routeID, direction: bus.direction)?
                    .progress(stopID: ride.boarding.id, vehicle: bus, at: date).map { $0.distance < -20 } ?? false
                Text(bus.plate + (passed ? AppText.text(" · 已離開上車站") : AppText.text(" · 位置更新中")))
                    .liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The officially timed next bus, listed even before its GPS appears on the route.
private struct NextBusRow: View {
    @Environment(\.liveSettings) private var live
    let guide: BoardingGuide
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bus.fill").liveFont(.subheadline, weight: .semibold).foregroundStyle(MapChrome.secondaryText)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(live.text("下一班")).liveFont(.body, weight: .semibold)
                Text(live.text(guide.emptyPositionLabel)).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(guide.arrivalShortLabel).liveFont(.body, weight: .bold).monospacedDigit()
                .liveNumericText(guide.arrivalShortLabel, countsDown: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine).accessibilityIdentifier("boarding-next-bus-without-position")
    }
}

struct VehicleArrivalsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let guide = BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: timeline.date)
                List {
                    Section {
                        HStack { BilingualName(ride.boarding); Spacer(); Text(guide.arrivalShortLabel).bold().monospacedDigit().liveNumericText(guide.arrivalShortLabel, countsDown: true) }
                        Text(AppText.text("往 ") + ride.route.localizedDestination(direction: ride.direction)).foregroundStyle(MapChrome.secondaryText)
                    } header: { Text(AppText.text("官方下一班")) }
                    Section {
                        if guide.nextBusWithoutPosition { NextBusRow(guide: guide) }
                        else if guide.approaches.isEmpty { Text(live.text(guide.emptyPositionLabel)).foregroundStyle(MapChrome.secondaryText) }
                        ForEach(guide.approaches) { approach in
                            VStack(alignment: .leading, spacing: 3) {
                                BoardingVehicleRow(model: model, ride: ride, approach: approach, date: timeline.date)
                                let display = model.arrivalDisplay(approach.vehicle, stopID: ride.boarding.id, at: timeline.date)
                                DisclosureGroup("時間說明") {
                                    Text(display.positionLabel)
                                    if let prediction = display.prediction { Text(prediction.rangeLabel) }
                                    Text(display.explanation)
                                    Text(AppText.text("車輛位置更新於 ") + approach.vehicle.observedAt.formatted(date: .omitted, time: .standard))
                                }.liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                            }
                        }
                    } header: { Text(AppText.text("%@ · 已發車車輛", ride.route.localizedName)) }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle(AppText.text("到站車輛")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppText.text("完成")) { dismiss() }.accessibilityIdentifier("journey-vehicles-done") } }
        }.presentationDetents([.large])
    }
}

private struct BoardingVehicleRow: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let approach: VehicleApproach
    let date: Date
    private var selected: Bool { model.selectedVehicleID == approach.id }
    private var tracking: Bool { selected && model.following }
    private var nextStop: String? {
        model.metadata.journey(routeID: approach.vehicle.routeID, direction: approach.vehicle.direction)?
            .upcoming(vehicle: approach.vehicle, at: date).first?.stop.localizedName
    }
    var body: some View {
        Button {
            if tracking { model.following = false }
            else { model.trackApproachingVehicle(approach.vehicle) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(approach.vehicle.plate).liveFont(.subheadline, weight: .semibold).monospaced()
                    if selected { Text(nextStop.map { AppText.text("前方 · ") + $0 } ?? AppText.text("位置待確認")).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).lineLimit(1) }
                }
                Spacer(minLength: 4)
                let arrival = model.arrivalDisplay(approach.vehicle, stopID: ride.boarding.id, at: date).label
                Text(arrival)
                    .liveFont(.subheadline, weight: .semibold, design: .rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    .liveNumericText(arrival, countsDown: true)
                Label(tracking ? AppText.text("追蹤中") : AppText.text("追蹤"), systemImage: "scope").liveFont(.caption, weight: .semibold)
                    .foregroundStyle(tracking ? Color.white : Color(liveHex: live.appearance.accentColor))
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .background(Color(liveHex: live.appearance.accentColor).opacity(tracking ? 1 : 0.12), in: Capsule())
                    .smoothChanges(tracking)
            }.frame(minHeight: 48).padding(.vertical, 2 * CGFloat(live.appearance.spacingScale)).padding(.horizontal, 14).contentShape(Rectangle())
        }.buttonStyle(PhonePressStyle()).foregroundStyle(.primary).accessibilityHint(tracking ? AppText.text("停止追蹤") : AppText.text("點一下追蹤這輛公車"))
            .accessibilityValue(tracking ? AppText.text("追蹤中") : selected ? AppText.text("已選擇") : "")
            .accessibilityIdentifier("boarding-vehicle-" + approach.vehicle.plate)
    }
}

private struct OnboardSummary: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ride.route.mode != .bus {
                MetroOnboardSummary(model: model, ride: ride, date: date)
            } else {
                let bus = model.onboardVehicle(for: ride)
                let journey = bus.flatMap { model.metadata.journey(routeID:$0.routeID,direction:$0.direction) }
                let next = model.onboardStops(for: ride, at: date).first
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.map { AppText.text("下一站 · ") + $0.localizedName } ?? AppText.text("位置更新中")).lineLimit(2)
                        if live.language == .english, let next { Text(next.name).liveFont(.caption).foregroundStyle(MapChrome.secondaryText) }
                    }
                    Spacer()
                    if let next {
                        VStack(alignment: .trailing, spacing: 2) {
                            let nextTime = model.onboardStopTimeLabel(ride, stopID: next.id, at: date)
                            Text(nextTime).lineLimit(2).minimumScaleFactor(0.75).liveNumericText(nextTime, countsDown: true)
                            Text(AppText.remainingStops(1)).liveFont(.caption)
                        }.monospacedDigit().frame(width: live.language == .english ? 115 : 110, alignment: .trailing)
                    }
                }.liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText).accessibilityElement(children: .combine).accessibilityIdentifier("journey-next-stop")
                let progress = bus.flatMap { journey?.progress(stopID:ride.alighting.id,vehicle:$0,at:date) }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((progress?.distance ?? 0) < -20 ? AppText.text("已通過「%@」", ride.alighting.localizedName) : AppText.text("在「%@」下車", ride.alighting.localizedName))
                            .liveFont(.title3, weight: .bold).lineLimit(2)
                        if live.language == .english { Text(ride.alighting.name).liveFont(.caption).foregroundStyle(MapChrome.secondaryText) }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        let alighting = model.onboardStopTimeLabel(ride, stopID: ride.alighting.id, at: date)
                        Text(alighting)
                            .liveFont(.title3, weight: .bold).monospacedDigit().lineLimit(2).minimumScaleFactor(0.75)
                            .liveNumericText(alighting, countsDown: true)
                            .frame(maxWidth: live.language == .english ? 115 : 110, alignment: .trailing)
                        if let count = model.onboardStops(for: ride, at: date).firstIndex(where: { $0.id == ride.alighting.id }) {
                            Text(AppText.remainingStops(count + 1)).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                        }
                    }
                }.accessibilityElement(children: .combine).accessibilityIdentifier("journey-alighting-time")
            }
        }
    }
}

private struct OnboardStopsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let stops = ride.route.mode == .bus ? model.onboardStops(for: ride, at: timeline.date) : model.metroRemaining(ride, at: timeline.date).stops
                List {
                    Section {
                        if ride.route.mode != .bus {
                            Text(AppText.text("依站間車程估計 · 到站請確認站名")).foregroundStyle(MapChrome.secondaryText)
                        } else if let plate = model.onboardPlate(for: ride) {
                            Text(plate).monospaced().bold().accessibilityIdentifier("onboard-confirmed-plate")
                            Text(model.onboardPositionSource(ride,at:timeline.date)).foregroundStyle(MapChrome.secondaryText)
                        } else { Text(model.onboardPositionSource(ride,at:timeline.date)).foregroundStyle(MapChrome.secondaryText) }
                    } header: { Text(ride.route.localizedName + AppText.text(" · 往 ") + ride.route.localizedDestination(direction: ride.direction)) }
                    Section {
                        ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                            HStack(spacing: 12) {
                                Image(systemName: stop.id == ride.alighting.id ? "arrow.down.circle.fill" : "circle.fill")
                                    .font(.system(size: stop.id == ride.alighting.id ? 20 : 8))
                                    .foregroundStyle(stop.id == ride.alighting.id ? Color.orange : Color.secondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    BilingualName(stop).liveFont(.subheadline, weight: stop.id == ride.alighting.id ? .bold : .regular)
                                    if stop.id == ride.alighting.id { Text(AppText.text("在這裡下車")).liveFont(.caption).foregroundStyle(.orange) }
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(ride.route.mode != .bus ? model.metroStopLabel(ride, stop: stop, at: timeline.date) : model.onboardStopTimeLabel(ride, stopID:stop.id,at:timeline.date))
                                        .liveFont(.subheadline, weight: .semibold).monospacedDigit().lineLimit(2)
                                    Text(AppText.remainingStops(index + 1)).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                                }.frame(maxWidth: live.language == .english ? 115 : 110, alignment: .trailing)
                            }.frame(minHeight: 40).accessibilityIdentifier("onboard-stop-" + stop.id)
                        }
                    } header: { Text(AppText.text("這輛車的沿途預估")) } footer: {
                        Text(ride.route.mode != .bus ? AppText.text("依官方捷運站間車程") : AppText.text("時間依行駛情況更新，塞車與停靠可能影響預估。"))
                    }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle(ride.route.mode == .bus ? AppText.text("沿途站牌") : AppText.text("沿線車站")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppText.text("完成")) { dismiss() }.accessibilityIdentifier("journey-stops-done") } }
        }.presentationDetents([.large])
    }
}

private struct BoardedVehiclePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    @State private var showingScanner = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showingScanner = true } label: {
                        Label(AppText.text("掃描車牌"), systemImage: "camera")
                    }.accessibilityIdentifier("boarding-scan-plate")
                }
                Section {
                    let vehicles = BoardingGuide.vehicles(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: Date(), approachingOnly: false)
                    if vehicles.isEmpty { Text(AppText.text("暫無車輛位置，稍後再選擇")).foregroundStyle(MapChrome.secondaryText) }
                    ForEach(vehicles) { approach in
                        Button {
                            model.confirmBoardedVehicle(approach.vehicle, ride: ride); dismiss()
                        } label: {
                            HStack {
                                Text(approach.vehicle.plate).monospaced()
                                Spacer()
                                if model.onboardPlate(for: ride) == approach.vehicle.plate { Image(systemName: "checkmark") }
                            }.frame(minHeight: 40)
                        }.accessibilityIdentifier("onboard-choose-" + approach.vehicle.plate)
                    }
                } header: { Text(ride.route.localizedName + AppText.text(" · 往 ") + ride.route.localizedDestination(direction: ride.direction)) } footer: { Text(AppText.text("依車內或車身顯示的車牌選擇。")) }
            }.navigationTitle(AppText.text("搭乘車牌")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppText.text("取消")) { dismiss() } } }
        }.presentationDetents([.medium, .large])
            .sheet(isPresented: $showingScanner) {
                BoardingPlateScanner(model: model, ride: ride) { bus in
                    model.confirmBoardedVehicle(bus, ride: ride)
                    showingScanner = false; dismiss()
                }
            }
    }
}

/// The waiting stage of the trip card, below the header the card keeps for every stage.
private struct JourneyWaitingStage: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var body: some View {
        if let option = planner.selected, let index = planner.boardingRideIndex {
            let ride = option.rides[index]
            VStack(alignment: .leading, spacing: 10) {
                JourneyBoardingView(model: model, ride: ride)
                if index > 0 {
                    Text(option.walks[index].timeLabel).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                }
                JourneyWaitingActions(model: model, planner: planner, index: index) { model.boardCurrentRide() }
            }
        }
    }
}

private struct JourneyDockHeader: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let showJourney: () -> Void
    @State private var confirmingEnd = false
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
    }
    var body: some View {
        layout { heading; actions }
        .alert(AppText.text("結束這趟導航？"), isPresented: $confirmingEnd) {
            Button(AppText.text("結束行程"), role: .destructive) { model.finishJourney() }
                .accessibilityIdentifier("journey-confirm-end")
            Button(AppText.text("繼續導航"), role: .cancel) {}
        } message: { Text(AppText.text("行程資訊與下車提醒會一起停止。")) }
    }
    private func summary(_ duration: JourneyDuration) -> String {
        let total = planner.started ? duration.summaryLabel(remaining: true) : duration.label
        let arrival = duration.expectedArrivalLabel
        let zone = duration.timeZoneNote().map { " · " + $0 } ?? ""
        return total + " · " + arrival + zone
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
                Text(planner.destination?.localizedName ?? AppText.text("目的地")).liveFont(.headline, weight: .bold).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                if let option = planner.selected {
                    TimelineView(.periodic(from: .now, by: 15)) { timeline in
                        if let duration = model.journeyDuration(option, at: timeline.date) {
                            let label = summary(duration)
                            Text(label)
                                .liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText).monospacedDigit().lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                .accessibilityIdentifier("journey-total-duration")
                                .liveNumericText(label)
                        }
                    }
                }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: showJourney) {
                Image(systemName: "list.bullet").liveFont(.body, weight: .semibold).frame(width: 48, height: 48)
            }
            .buttonStyle(MapActionStyle(tint: Color.primary))
            .accessibilityLabel(live.text(planner.started ? "行程" : "路線"))
            .accessibilityIdentifier("journey-options")
            Button { if planner.arrived { model.finishJourney() } else { confirmingEnd = true } } label: {
                Text(AppText.text("結束")).liveFont(.subheadline, weight: .bold).padding(.horizontal, 14).frame(minHeight: 48)
            }
            .buttonStyle(MapActionStyle(tint: MapChrome.destructive))
            .accessibilityLabel(live.text("結束行程"))
            .accessibilityIdentifier("journey-end")
        }.frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .trailing)
    }
}

private struct JourneyDockSurface: ViewModifier {
    @Environment(\.liveSettings) private var live
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = live.shape(.card)
        content.padding(.horizontal, 16 * CGFloat(live.appearance.spacingScale)).padding(.top, 14)
            .padding(.bottom, 16)
            .background {
                if reduceTransparency || live.appearance.solidSurfaces { shape.fill(Color(uiColor: .secondarySystemBackground)) }
                else { shape.fill(.thickMaterial) }
            }
            .overlay { shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.16 : 0.07), lineWidth: 0.6) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.14), radius: 18, y: 6)
    }
}
extension View {
    func journeyDockSurface() -> some View { modifier(JourneyDockSurface()) }
}

private struct JourneyWaitingActions: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let index: Int
    let board: () -> Void
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
    }
    /// Still well short of the stop: walking is the next thing to do, so it carries the
    /// prominent style; "已上車" takes it back once the rider is there or progress is unknown.
    private var stillWalking: Bool {
        guard planner.walkingLegIndex == index, let progress = planner.walkingProgress,
              progress.hasConfirmedProgress else { return false }
        return progress.remainingDistance > 80
    }
    var body: some View {
        VStack(spacing: 6) {
            layout {
                if planner.selected?.walks.indices.contains(index) == true, planner.selected?.walks[index].internalTransfer != true {
                let cycling = planner.selected?.walks[index].bike != nil
                Button { model.showWalkOnMap(index) } label: {
                    Label(cycling ? live.text("騎到站牌") : planner.activeRide?.route.mode == .bus ? live.text("走到站牌") : live.text("走到車站"),
                          systemImage: cycling ? "bicycle" : "figure.walk")
                        .liveFont(.body, weight: .semibold).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 50)
                }.buttonStyle(MapActionStyle(prominent: stillWalking)).tripStageMatch("dock-secondary")
                    .disabled(planner.selected?.verified != true || planner.selected?.walkIssue != nil)
                    .accessibilityHint(AppText.text("在目前地圖查看步行路線"))
                    .accessibilityIdentifier("journey-walk-to-stop")
                }
                Button(action: board) {
                    Text(live.text("已上車")).liveFont(.body, weight: .bold).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }.buttonStyle(MapActionStyle(prominent: !stillWalking)).tripStageMatch("dock-primary")
                    .disabled(planner.selected?.verified != true || planner.selected?.walkIssue != nil)
                    .accessibilityIdentifier("journey-board")
            }
            if let option = planner.selected, index == 0 {
                if planner.checkingWalks { ProgressView().controlSize(.small) }
                else if let walk = option.walks.first, let duration = walk.duration, duration >= 30 {
                    Text(planner.walkingStatus(at: index) ?? walk.timeLabel).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).accessibilityIdentifier("walking-live-status")
                }
                if let issue = option.walkIssue { Text(live.text(issue)).liveFont(.caption).foregroundStyle(MapChrome.caution) }
                if option.walks.first?.bike != nil {
                    if let bike = option.walks.first?.bike { JourneyBikeStations(model: model, bike: bike, index: index, compact: true) }
                    if let instruction = planner.cyclingInstruction(at: index) {
                        Text(instruction).liveFont(.caption, weight: .semibold).accessibilityIdentifier("cycling-live-instruction")
                    }
                    BikeStationAlert(model: model, planner: planner)
                }
            }
        }
    }
}

/// Route signs wrap as complete segments instead of shrinking a mixed trip into tiny text.
private struct JourneyChainLayout: Layout {
    var spacing: CGFloat = 6
    private func arrangement(_ subviews: Subviews, width: CGFloat) -> (sizes: [CGSize], points: [CGPoint], height: CGFloat) {
        var sizes: [CGSize] = [], points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for item in subviews {
            let natural = item.sizeThatFits(.unspecified)
            let size = natural.width > width ? item.sizeThatFits(ProposedViewSize(width:width,height:nil)) : natural
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            sizes.append(size); points.append(CGPoint(x:x,y:y))
            x += size.width + spacing; row = max(row,size.height)
        }
        return (sizes,points,y + row)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width + spacing }.reduce(0,+)
        return CGSize(width:width,height:arrangement(subviews,width:max(1,width)).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let result = arrangement(subviews,width:max(1,bounds.width))
        for index in subviews.indices {
            subviews[index].place(at:CGPoint(x:bounds.minX + result.points[index].x,y:bounds.minY + result.points[index].y),
                anchor:.topLeading,proposal:ProposedViewSize(width:result.sizes[index].width,height:result.sizes[index].height))
        }
    }
}

private struct JourneyRouteChain: View {
    let option: JourneyOption
    var body: some View {
        JourneyChainLayout {
            ForEach(option.walks.indices, id: \.self) { index in
                if option.rides.indices.contains(index) || (option.walks[index].duration ?? 0) >= 30 {
                HStack(spacing: 5) {
                if let duration = option.walks[index].duration, duration >= 30 {
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    if let bike = option.walks[index].bike {
                        if bike.toPickupSeconds >= 30 {
                            time(bike.toPickupSeconds, symbol: "figure.walk")
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        time(bike.rideSeconds, symbol: "bicycle")
                            .accessibilityLabel(AppText.text("騎車 %@ 分", bike.ridingMinutes))
                            .accessibilityIdentifier("journey-chain-bike-\(index)")
                        if bike.fromDropoffSeconds >= 30 {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            time(bike.fromDropoffSeconds, symbol: "figure.walk")
                        }
                    } else {
                        time(duration, symbol: "figure.walk")
                    }
                }
                if option.rides.indices.contains(index) {
                    if index > 0 || (option.walks[index].duration ?? 0) >= 30 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    RouteBadge(name: option.rides[index].route.mode == .bus ? option.rides[index].route.localizedName : option.rides[index].route.lineCode, tintName: option.rides[index].route.name, compact: true)
                        .fixedSize(horizontal:true,vertical:false)
                    Image(systemName: option.rides[index].route.mode == .bus ? "bus.fill" : "tram.fill")
                        .liveFont(.subheadline, weight: .semibold).foregroundStyle(.primary).accessibilityHidden(true)
                }
                }.fixedSize(horizontal:true,vertical:false)
                }
            }
        }.lineLimit(1)
    }
    private func time(_ seconds: Double, symbol: String) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
            Text("\(max(1, Int(ceil(seconds / 60))))")
        }.liveFont(.subheadline, weight: .semibold).foregroundStyle(MapChrome.secondaryText).monospacedDigit()
            .accessibilityElement(children: .combine)
    }
}

struct JourneyOptionsView: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var previewHeight: CGFloat = 146
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let collapse: () -> Void
    var compact = false
    var expand: () -> Void = {}
    var showSteps: () -> Void = {}
    var go: (JourneyOption) -> Void = { _ in }
    private var spacious: Bool { dynamicTypeSize.isAccessibilitySize || live.appearance.textScale > 1.25 }
    private var comparisons: [JourneyOption] { Array(planner.options.filter { $0.id != planner.selectedID }.prefix(2)) }
    var body: some View {
        TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 15)) { timeline in
            content(at: timeline.date)
        }
        .onChange(of: planner.selectedID, initial: true) { _, _ in planner.retainVisiblePreview() }
        // Notices that name a route on these options are marked on them.
        .task(id: planner.options.count) { if !planner.options.isEmpty { await model.refreshNotices() } }
    }
    @ViewBuilder private func content(at date: Date) -> some View {
        // Before the first option arrives, placeholder rows hold the space the options will
        // fill; once some are listed, a further search shows only the small progress row.
        let awaitingFirst = planner.options.isEmpty && planner.message == nil
            && (planner.planning || model.loading || planner.checkingWalks)
        let noOptions = planner.emptyOptionsMessage != nil && !model.loading
        VStack(alignment: .leading, spacing: 0) {
            if awaitingFirst {
                LoadingRows(count: compact ? 2 : 3, label: live.text("查詢中"))
                    .accessibilityIdentifier("journey-options-loading")
            } else if planner.planning || model.loading {
                HStack(spacing: 10) { ProgressView(); Text(live.text("查詢中")).liveFont(.subheadline) }.padding(.vertical, 8)
            }
            if let message = planner.message ?? (model.loading ? nil : planner.emptyOptionsMessage) {
                if noOptions {
                    EmptyStateView(symbol: "bus", message: live.text(message)) {
                        ViewThatFits {
                            HStack(spacing: 10) { emptyOptionActions }
                            VStack(spacing: 8) { emptyOptionActions }
                        }.liveFont(.subheadline, weight: .semibold)
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("journey-empty-options-message")
                } else {
                    Text(live.text(message)).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText)
                        .accessibilityIdentifier("journey-empty-options-message")
                }
            }
            if compact, !planner.options.isEmpty {
                if spacious, let option = planner.selected ?? planner.featuredOptions.first {
                    VStack(alignment: .leading, spacing: 16) {
                        summary(option, at: date, compact: true)
                        HStack(spacing: 12) {
                            stepsButton(option).frame(maxWidth: .infinity)
                            goButton(option).frame(maxWidth: .infinity)
                        }
                    }.padding(16).background(Color(uiColor: .tertiarySystemFill), in: live.shape(.panel))
                } else {
                // Keep the actions outside the paging collection. Its gesture handling and
                // recycled pages must never swallow a Steps/Go tap during a clock update.
                HStack(spacing: 12) {
                TabView(selection: Binding(get: { planner.selectedID ?? planner.options.first?.id ?? "" }, set: { id in
                    if id != planner.selectedID, let option = planner.options.first(where: { $0.id == id }) { planner.select(option) }
                })) {
                    ForEach(planner.featuredOptions) { option in compactSummary(option, at: date).tag(option.id) }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .clipped().contentShape(Rectangle())
                .animation(InterfaceMotion.reduced(systemReduceMotion) ? nil : .smooth(duration: 0.25), value: planner.selectedID)
                .accessibilityIdentifier("journey-preview-pages")
                if let option = planner.selected ?? planner.featuredOptions.first { compactActions(option).zIndex(1) }
                }
                .frame(height: previewHeight * CGFloat(max(1, live.appearance.textScale)) + (live.language == .english ? 22 : 0))
                .padding(14)
                .background(Color(uiColor: .tertiarySystemFill), in: live.shape(.panel))
                .padding(.horizontal, 1)
                }
                if !comparisons.isEmpty {
                    if spacious {
                        VStack(spacing: 8) { ForEach(comparisons) { comparison($0, at: date) } }.padding(.top, 10)
                    } else {
                        HStack(spacing: 8) { ForEach(comparisons) { comparison($0, at: date) } }.padding(.top, 10)
                    }
                }
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        ForEach(Array(planner.featuredOptions.enumerated()), id: \.element.id) { index, option in
                            Button { planner.select(option) } label: {
                                Circle().fill(option.id == planner.selectedID ? Color.primary : Color.secondary.opacity(0.3))
                                    .frame(width: 6, height: 6).frame(width: 20, height: 44)
                            }.accessibilityLabel(AppText.text("路線方案 %@", index + 1))
                                .accessibilityIdentifier("journey-page-\(index)")
                        }
                    }
                    Button(action: expand) {
                        HStack(spacing: 4) {
                            Text(AppText.text("全部路線"))
                            if planner.options.count > 5 { Text("\(planner.options.count)").foregroundStyle(MapChrome.secondaryText).monospacedDigit() }
                        }.liveFont(.subheadline).frame(minHeight: 44)
                    }.accessibilityElement(children: .combine)
                        .accessibilityLabel(AppText.text("全部路線"))
                        .accessibilityValue("\(planner.options.count)")
                        .accessibilityIdentifier("journey-all-options")
                    // Return to the first recommendation without replacing the inspected map automatically.
                    if planner.comparisonChanged, !planner.checkingWalks {
                        Button { planner.refreshRecommendations() } label: {
                            Label(AppText.text("查看推薦"), systemImage: "arrow.uturn.backward")
                                .liveFont(.caption, weight: .semibold).padding(.horizontal, 10).frame(minHeight: 32)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .frame(minHeight: 44)
                        }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            .accessibilityIdentifier("journey-refresh-options")
                            .transition(.opacity)
                    }
                    Spacer(minLength: 4)

                }.padding(.top, 4)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(planner.options) { option in
                        optionRow(option, at: date)
                        if option.id != planner.options.last?.id { Divider() }
                    }
                }
            }
            if planner.checkingWalks {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppText.text(planner.options.isEmpty ? "確認接駁與其他方案" : "繼續比較其他方案"))
                        .liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                }.padding(.vertical, 8).accessibilityElement(children: .combine)
                    .accessibilityIdentifier("journey-comparing-alternatives")
            }
            if planner.comparisonChanged, !planner.checkingWalks, !compact {
                Button { planner.refreshRecommendations() } label: {
                    Label(AppText.text("查看推薦"), systemImage: "arrow.clockwise").liveFont(.subheadline).frame(minHeight: 44)
                }.accessibilityIdentifier("journey-refresh-options")
            }
        }
    }
    @ViewBuilder private var emptyOptionActions: some View {
        Button { planner.plan(metadata:model.metadata) } label: {
            Label(AppText.text("重新查詢"),systemImage:"arrow.clockwise").frame(minHeight:44)
        }.buttonStyle(.bordered).accessibilityIdentifier("journey-retry-search")
        Button { planner.openAppleTransit() } label: {
            Label(AppText.text("其他交通方式"), systemImage: "arrow.up.right.square").frame(minHeight:44)
        }.buttonStyle(.bordered).accessibilityIdentifier("journey-empty-other-transport")
    }
    private func usable(_ option: JourneyOption) -> Bool {
        planner.canUse(option)
    }
    /// A trip planned for later is started when it is time, from the same route.
    private func startable(_ option: JourneyOption) -> Bool {
        planner.scheduledDeparture == nil && usable(option)
    }
    private func compactSummary(_ option: JourneyOption, at date: Date) -> some View {
        Button { planner.select(option); collapse() } label: {
                summary(option, at: date, compact: true).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(PhonePressStyle()).foregroundStyle(.primary)
                .accessibilityIdentifier("journey-option-" + option.id)
    }
    private func compactActions(_ option: JourneyOption) -> some View {
        VStack(spacing: 6) {
            goButton(option).frame(width: 66, height: 62)
            stepsButton(option).frame(width: 66, height: 48)
        }.frame(width: 66)
    }
    private func goButton(_ option: JourneyOption) -> some View {
        Button { go(option) } label: {
            Text(AppText.text("出發")).liveFont(.body, weight: .bold)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 56)
        }.buttonStyle(MapTileStyle(prominent: true, tint: MapChrome.go))
                    .disabled(!startable(option)).opacity(startable(option) ? 1 : 0.42)
                    .accessibilityLabel(AppText.text("開始導航"))
                    .accessibilityIdentifier("journey-go-" + option.id)
    }
    private func stepsButton(_ option: JourneyOption) -> some View {
        Button {
#if DEBUG
                    model.recordMapTap("journey-steps:" + option.id)
#endif
                    planner.select(option); showSteps()
                } label: {
                    HStack(spacing: 3) {
                        Text(AppText.text("步驟")); Image(systemName: "chevron.right")
                    }.liveFont(.caption, weight: .semibold).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(MapActionStyle())
                    // Preview remains available when current supply prevents Go.
                    .disabled(!option.verified)
                    .accessibilityLabel(AppText.text("查看搭乘步驟"))
                    .accessibilityIdentifier("journey-steps-" + option.id)
    }
    private func comparison(_ option: JourneyOption, at date: Date) -> some View {
        let timing = model.journeyDuration(option, at: date)
        let routes = option.rides.map { $0.route.mode == .bus ? $0.route.localizedName : $0.route.lineCode }.joined(separator: " → ")
        return Button { planner.select(option) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(timing?.conciseLabel ?? AppText.text("確認接駁中")).liveFont(.subheadline, weight: .semibold).monospacedDigit()
                    Spacer(minLength: 0)
                    if let fare = model.fareLabel(option) { Text(fare).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).monospacedDigit() }
                    Image(systemName: "chevron.right").liveFont(.caption2).foregroundStyle(MapChrome.secondaryText)
                }
                HStack(spacing: 4) {
                    if option.cycles { Image(systemName: "bicycle") }
                    Text(routes.isEmpty ? AppText.text(option.cycles ? "騎 YouBike" : "步行即可") : routes)
                    if let label = planner.optionLabels[option.id] { Text(live.text(label)).foregroundStyle(MapChrome.secondaryText) }
                }.liveFont(.caption).lineLimit(spacious ? nil : 1)
            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color(uiColor: .tertiarySystemFill).opacity(0.7), in: live.shape(.row))
                .contentShape(live.shape(.row))
        }.buttonStyle(PhonePressStyle()).foregroundStyle(.primary)
            .accessibilityElement(children: .combine)
            .accessibilityHint(AppText.text("預覽此路線"))
            .accessibilityIdentifier("journey-compare-" + option.id)
    }
    private func optionRow(_ option: JourneyOption, at date: Date) -> some View {
        Button { planner.select(option); collapse() } label: {
            HStack(spacing: 12) {
                summary(option, at: date, compact: false).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: option.id == planner.selectedID ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(option.id == planner.selectedID ? Color(liveHex: live.appearance.accentColor) : Color.secondary)
            }.padding(.vertical, 14).contentShape(Rectangle())
        }.buttonStyle(PhonePressStyle()).foregroundStyle(.primary)
            .accessibilityIdentifier("journey-option-" + option.id)
            .accessibilityHint(AppText.text("預覽此路線"))
    }
    private func summary(_ option: JourneyOption, at date: Date, compact: Bool) -> some View {
        let timing = model.journeyDuration(option, at: date)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(timing?.conciseLabel ?? AppText.text("確認接駁中"))
                    .liveFont(compact ? .title2 : .title3, weight: .bold, design: .rounded)
                    .monospacedDigit().fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                    .accessibilityIdentifier("journey-preview-duration-" + option.id)
                if let label = planner.optionLabels[option.id] {
                    Text(live.text(label == "推薦" && planner.checkingWalks ? "比較中" : label)).liveFont(.caption2, weight: .semibold).foregroundStyle(MapChrome.secondaryText)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let timing {
                if !option.walkingOnly { Text(timing.expectedWaitingLabel).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText).monospacedDigit().fixedSize(horizontal: false, vertical: true) }
                JourneyArrivalTime(duration: timing)
            }
            if let fare = model.fareLabel(option) {
                Text(fare).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText).monospacedDigit()
                    .accessibilityIdentifier("journey-fare-" + option.id)
            }
            if let warning = model.noticeWarning(option) {
                Label(AppText.text("公告提到 %@：%@", warning.route, warning.notice.title), systemImage: "exclamationmark.triangle.fill")
                    .liveFont(.caption).foregroundStyle(.orange).lineLimit(spacious ? nil : 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityIdentifier("journey-notice-" + option.id)
            }
            JourneyRouteChain(option: option).padding(.top, 5)
            if let reason = planner.optionReasons[option.id] {
                Text(reason).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).lineLimit(spacious ? nil : 2)
                    .accessibilityIdentifier("journey-recommendation-reason")
            }
            if live.language == .english, let first = option.rides.first, let last = option.rides.last {
                Text(first.boarding.name + " → " + last.alighting.name).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).lineLimit(spacious ? nil : 1)
            }
            if let unavailable = planner.unavailableBoarding(option) {
                Text(unavailable.route + " · " + EstimateFeed.label(unavailable.status)).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
            }
        }
    }
}

private struct JourneySavedShortcuts: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject private var library: CommuteLibrary
    let choose: (SavedJourney) -> Void
    init(model: TransitAppModel, choose: @escaping (SavedJourney) -> Void) {
        self.model = model; library = model.commutes; self.choose = choose
    }
    var body: some View {
        if !library.journeys.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppText.text("常用行程")).liveFont(.subheadline, weight: .semibold)
                ForEach(library.journeys.prefix(3)) { saved in
                    Button { choose(saved) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: saved.symbol).foregroundStyle(.tint).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(saved.title).liveFont(.body, weight: .medium)
                                Text((saved.origin?.localizedName ?? AppText.text("目前位置")) + " → " + saved.destination.localizedName)
                                    .liveFont(.caption).foregroundStyle(MapChrome.secondaryText).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                        }.frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(PhonePressStyle()).foregroundStyle(.primary)
                        .accessibilityIdentifier("journey-saved-" + saved.id.uuidString)
                        .accessibilityHint(AppText.text("預覽此路線"))
                }
            }.padding(.vertical, 8)
        }
    }
}

private struct JourneyArrivalTime: View {
    let duration: JourneyDuration
    var body: some View {
        Text(duration.expectedArrivalLabel + (duration.timeZoneNote().map { " · " + $0 } ?? ""))
            .liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct JourneyTimingExplanation: View {
    let duration: JourneyDuration
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(AppText.text("行程時間說明")).liveFont(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark.circle.fill").liveFont(.title3).frame(width: 48, height: 48) }
                    .buttonStyle(.plain).foregroundStyle(MapChrome.secondaryText)
                    .accessibilityLabel(AppText.text("關閉時間說明")).accessibilityIdentifier("journey-time-close")
            }.padding(.horizontal, 20).padding(.top, 12)
            ScrollView { breakdown }
        }.frame(idealWidth: 320, maxWidth: 420, minHeight: 160, idealHeight: 420, maxHeight: 600)
    }
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(duration.components) { component in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(component.title).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(component.durationLabel).monospacedDigit().fixedSize()
                }.accessibilityElement(children: .combine)
                    .accessibilityIdentifier("journey-time-component-" + component.kind.rawValue)
            }
            Divider()
            Text(duration.waitingLabel)
            Text(duration.arrivalLabel)
            if let note = duration.timeZoneNote() { Text(note).foregroundStyle(MapChrome.secondaryText) }
            if duration.ridingSeconds > 0 { Text(duration.ridingSourceLabel).foregroundStyle(MapChrome.secondaryText) }
            Text(AppText.text("總時間已包含步行、候車、進出站及取還車；不需另外相加。"))
                .foregroundStyle(MapChrome.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.liveFont(.subheadline).padding(20)
    }
}

struct JourneyItineraryView: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var showMap: () -> Void = {}
    @State private var showTimingInfo = false
    var body: some View {
        if let option = planner.selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(planner.destination?.localizedName ?? AppText.text("目的地"))
                        .liveFont(.title2, weight: .bold).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("journey-destination-title")
                    if live.language == .english, let name = planner.destination?.name { Text(name).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText) }
                    TimelineView(.periodic(from: Date(timeIntervalSince1970: 0), by: 15)) { timeline in
                        if let duration = model.journeyDuration(option, at: timeline.date) {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(planner.started ? duration.summaryLabel(remaining: true) : duration.conciseLabel)
                                        .liveFont(.headline).monospacedDigit()
                                    JourneyArrivalTime(duration: duration)
                                }.accessibilityElement(children: .combine).accessibilityIdentifier("journey-duration-breakdown")
                                Spacer()
                                Button { showTimingInfo = true } label: { Image(systemName: "info.circle").frame(width: 48, height: 48) }
                                    .accessibilityLabel(AppText.text("行程時間說明")).accessibilityIdentifier("journey-time-info")
                                    .popover(isPresented: $showTimingInfo) {
                                        JourneyTimingExplanation(duration: duration) { showTimingInfo = false }
                                            .environment(\.dynamicTypeSize, dynamicTypeSize)
                                            .presentationCompactAdaptation(.popover)
                                    }
                            }
                        }
                    }
                }.padding(.bottom, 18)
                ForEach(option.walks.indices, id: \.self) { index in
                    if option.walks[index].bike != nil {
                        JourneyCyclingStep(model: model, planner: planner, option: option, index: index, showMap: showMap)
                    } else {
                        JourneyWalkingStep(model: model, planner: planner, option: option, index: index, showMap: showMap)
                    }
                    Divider().padding(.leading, 48)
                    if option.rides.indices.contains(index) {
                        JourneyRideStep(model: model, planner: planner, option: option, index: index, showMap: showMap)
                        Divider().padding(.leading, 48)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "mappin.circle.fill").liveFont(.title2).foregroundStyle(.red).frame(width: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppText.text("抵達")).liveFont(.headline)
                        Text(planner.destination?.localizedName ?? AppText.text("目的地")).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText)
                    }
                }.padding(.vertical, 16)
            }
        }
    }
}

private struct JourneyWalkingStep: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let option: JourneyOption
    let index: Int
    let showMap: () -> Void
    private var leg: WalkingLeg { option.walks[index] }
    private var walked: Bool { planner.started && (planner.steps.firstIndex(of: .walk(index)) ?? .max) < planner.stepIndex }
    private var target: String { option.rides.indices.contains(index) ? option.rides[index].boarding.localizedName : planner.destination?.localizedName ?? AppText.text("目的地") }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "figure.walk").liveFont(.title2).foregroundStyle(.primary).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(leg.internalTransfer ? AppText.text("站內轉乘 · %@",target) : (walked ? AppText.text("已走到 ") : AppText.text("步行至 ")) + target)
                    .liveFont(.headline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("journey-walk-status-\(index)")
                if live.language == .english, option.rides.indices.contains(index) {
                    Text(option.rides[index].boarding.name).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                }
                Text(walked ? AppText.text("已完成") : (leg.distance.map { distanceLabel($0) + " · " } ?? "") + leg.timeLabel)
                    .liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText)
                if let instruction = leg.stationInstruction { Text(instruction).liveFont(.caption).foregroundStyle(MapChrome.secondaryText) }
            }
            Spacer(minLength: 0)
            if !walked, !leg.internalTransfer, planner.currentStep == .walk(index) {
                Button { model.showWalkOnMap(index); showMap() } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond").liveFont(.title3).frame(width: 40, height: 44)
                }.accessibilityLabel(planner.started ? AppText.text("步行導航到%@", target) : AppText.text("預覽步行至%@", target))
                    .accessibilityIdentifier("journey-in-app-walk-\(index)")
            }
        }.padding(.vertical, 16)
    }
}

/// One leg ridden on a YouBike: where to pick the bike up, how far it is ridden, and where it
/// has to be returned. The counts are what the stations reported when the trip was planned;
/// a station that has since run out is called out by `BikeStationAlert`.
private struct JourneyCyclingStep: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let option: JourneyOption
    let index: Int
    let showMap: () -> Void
    private var leg: WalkingLeg { option.walks[index] }
    private var done: Bool { planner.started && (planner.steps.firstIndex(of: .walk(index)) ?? .max) < planner.stepIndex }
    private var target: String {
        option.rides.indices.contains(index) ? option.rides[index].boarding.localizedName
            : planner.destination?.localizedName ?? AppText.text("目的地")
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "bicycle").liveFont(.title2).foregroundStyle(.primary).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text((done ? AppText.text("已騎到 ") : AppText.text("騎 YouBike 至 ")) + target)
                    .liveFont(.headline).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("journey-bike-status-\(index)")
                if let bike = leg.bike {
                    JourneyBikeStations(model: model, bike: bike, index: index)
                    Text(done ? AppText.text("已完成")
                         : AppText.text("步行 %@ 分 · 騎 %@ · %@ 分", max(1, Int(ceil(bike.walkingSeconds / 60))),
                                        distanceLabel(bike.rideMeters), bike.ridingMinutes))
                        .liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText)
                    if !done, bike.handlingSeconds > 0 {
                        Text(AppText.text("全程已含取還車 %@ 分", max(1, Int(ceil(bike.handlingSeconds / 60)))))
                            .liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                            .accessibilityIdentifier("journey-bike-handling-\(index)")
                    }
                    if !done {
                        if let instruction = leg.stationInstruction {
                            Text(instruction).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                                .accessibilityIdentifier("journey-bike-station-access-\(index)")
                        }
                        BikeStationAlert(model: model, planner: planner)
                    }
                }
            }
            Spacer(minLength: 0)
            if !done, planner.currentStep == .walk(index) {
                Button { model.showWalkOnMap(index); showMap() } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond").liveFont(.title3).frame(width: 40, height: 44)
                }.accessibilityLabel(AppText.text("在地圖查看騎乘路線"))
                    .accessibilityIdentifier("journey-in-app-bike-\(index)")
            }
        }.padding(.vertical, 16)
    }
}

/// Counts move while the rider is on the way. When the station they are heading to can no
/// longer serve them, say so and offer the nearest one that can, without replanning the trip.
struct BikeStationAlert: View {
    @Environment(\.liveSettings) private var live
    /// Observed so the warning appears and clears as new counts arrive; the planner holds the
    /// same counts but does not publish them.
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var body: some View {
        // Tap when the station the rider is heading to stops being usable, not when an
        // existing alert is shown again.
        content.sensoryFeedback(.warning, trigger: planner.bikeAlert?.station.id) { _, new in new != nil }
    }
    @ViewBuilder private var content: some View {
        if let alert = planner.bikeAlert {
            let renting = alert.renting, station = alert.station, replacement = alert.replacement
            VStack(alignment: .leading, spacing: 6) {
                Label(renting ? AppText.text("%@ 目前沒有車", station.localizedName)
                              : AppText.text("%@ 目前沒有空位", station.localizedName),
                      systemImage: "exclamationmark.triangle.fill")
                    .liveFont(.caption, weight: .semibold).foregroundStyle(MapChrome.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("journey-bike-alert")
                if let replacement {
                    Button { planner.moveBikeStation(to: replacement, renting: renting) } label: {
                        Label(renting ? AppText.text("改到 %@ 借車", replacement.localizedName)
                                      : AppText.text("改到 %@ 還車", replacement.localizedName),
                              systemImage: "arrow.triangle.swap")
                            .liveFont(.caption, weight: .semibold).lineLimit(2)
                            .padding(.horizontal, 12).frame(minHeight: 44)
                    }.buttonStyle(MapActionStyle()).accessibilityIdentifier("journey-bike-switch")
                    .disabled(planner.changingBikeStation)
                    if planner.changingBikeStation { ProgressView().accessibilityLabel(AppText.text("正在確認新站點路線")) }
                    if let message = planner.bikeStationUpdateMessage {
                        Text(AppText.text(message)).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                    }
                } else {
                    Text(live.text("附近暫時沒有可替代的站點，可重新規劃行程。"))
                        .liveFont(.caption).foregroundStyle(MapChrome.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct JourneyRideStep: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let option: JourneyOption
    let index: Int
    let showMap: () -> Void
    private var ride: TransitRide { option.rides[index] }
    private var aboard: Bool { planner.started && planner.currentStep == .ride(index) }
    private var ridden: Bool { planner.started && (planner.steps.firstIndex(of: .ride(index)) ?? .max) < planner.stepIndex }
    private var tint: Color { RouteTint.accent(for: ride.route.name) }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The route's own sign colour, as on its badge and map line.
            Image(systemName: ride.route.mode == .bus ? "bus.fill" : "tram.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RouteTint.color(for: ride.route.name), in: live.shape(.badge))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ride.route.mode == .bus ? AppText.text("搭乘 %@ 公車", ride.route.localizedName) : AppText.text("搭乘 %@", ride.route.localizedName)).liveFont(.headline)
                        Text(AppText.text("往 %@", ride.route.localizedDestination(direction: ride.direction))).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.selectRoute(ride.route, direction: ride.direction, variantOnly: true, boardingStopID: ride.boarding.id); showMap()
                    } label: {
                        Text(ride.route.mode == .bus ? AppText.text("看公車") : AppText.text("看列車")).liveFont(.subheadline, weight: .semibold).foregroundStyle(tint)
                            .padding(.horizontal, 12).frame(minHeight: 34).background(tint.opacity(0.14), in: Capsule())
                            .frame(minHeight: 44)
                    }.buttonStyle(PhonePressStyle())
                }
                if aboard {
                    Text(AppText.text("搭乘中") + (model.onboardPlate(for: ride).map { " · " + $0 } ?? ""))
                        .liveFont(.subheadline).accessibilityIdentifier("journey-ride-status-\(index)")
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in OnboardSummary(model: model, ride: ride, date: timeline.date) }
                } else if ridden {
                    Text(AppText.text("已下車")).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText).accessibilityIdentifier("journey-ride-status-\(index)")
                } else {
                    TimelineView(.periodic(from: .now, by: 15)) { timeline in
                        VStack(alignment: .leading, spacing: 5) {
                            JourneyArrivalView(model: model, ride: ride, walk: option.walks[index])
                            if let duration = planner.duration(option, at: timeline.date), duration.waits.indices.contains(index), duration.waits[index].missedNext {
                                Text(AppText.text("可搭後續班次 · ") + duration.waits[index].label).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    // A route-coloured line joins the boarding and alighting stops, as on the map.
                    VStack(spacing: 0) {
                        Circle().strokeBorder(tint, lineWidth: 3).background(Circle().fill(Color(uiColor: .systemBackground)))
                            .frame(width: 14, height: 14)
                        Rectangle().fill(tint).frame(width: 4).frame(maxHeight: .infinity)
                        Circle().fill(tint).frame(width: 14, height: 14)
                    }.frame(width: 16).padding(.vertical, 2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(ride.boarding.localizedName)
                        if live.language == .english { Text(ride.boarding.name).liveFont(.caption).foregroundStyle(MapChrome.secondaryText) }
                        TimelineView(.periodic(from: .now, by: 15)) { timeline in
                            let estimate = model.plannedRideTime(ride, at: timeline.date)
                            Text(AppText.text("搭乘 %@ 站 · 約 %@ 分鐘", ride.stopCount, max(1, Int(ceil(estimate.seconds / 60)))))
                                .fontWeight(.semibold).foregroundStyle(tint).accessibilityIdentifier("journey-ride-time-\(index)")
                        }
                        Text(AppText.text("在「%@」下車", ride.alighting.localizedName))
                        if live.language == .english { Text(ride.alighting.name).liveFont(.caption).foregroundStyle(MapChrome.secondaryText) }
                    }
                }.liveFont(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 16)
    }
}

struct JourneyArrivalView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var walk: WalkingLeg?
    private var requiresVariantConfirmation: Bool {
        let allowed = model.metadata.routeIDs(serving: ride)
        return model.metadata.variants(routeID: ride.route.id).contains { variant in
            !allowed.contains(variant.id) && model.metadata.orderedStops(routeID: variant.id, direction: ride.direction)
                .contains { $0.id == ride.boarding.id || $0.stationID == ride.boarding.stationID }
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let eta = model.snapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: timeline.date)
            VStack(alignment: .leading, spacing: 4) {
                // Live arrivals say nothing about a trip planned for later.
                if model.planner.scheduledDeparture == nil {
                Text(ride.route.mode == .bus ? AppText.text("路線到站：%@", EstimateFeed.label(eta)) : model.metroWaitLabel(ride, at: timeline.date)).liveFont(.subheadline, weight: .medium).monospacedDigit()
                }
                if model.planner.scheduledDeparture == nil, ride.route.mode != .bus { Text(model.metroArrival(ride, at: timeline.date) == nil ? AppText.text("依官方班距估計") : AppText.text("官方下一班")).liveFont(.caption).foregroundStyle(MapChrome.secondaryText) }
                if requiresVariantConfirmation {
                    Text(AppText.text("上車前請確認「%@」走法。", ride.route.localizedDisplayName)).liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
                }
                if let eta, eta >= 0, let duration = walk?.duration, duration > Double(eta) + 45 {
                    Text(live.text("步行時間較長，這班可能趕不上。")).liveFont(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct JourneyAlternativePrompt: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let suggestion: TransitAppModel.JourneySuggestion
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(suggestion.savedSeconds.map { AppText.text("預計可省約 %@ 分", max(1,Int($0 / 60))) }
                    ?? AppText.text("有另一條可行路線"))
                    .liveFont(.subheadline, weight: .semibold).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if suggestion.option.walkingOnly { Label(AppText.text("步行"), systemImage: "figure.walk") }
                    ForEach(suggestion.option.walks.indices, id: \.self) { index in
                        if index > 0 && (suggestion.option.walks[index].bike != nil || suggestion.option.rides.indices.contains(index)) {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(MapChrome.secondaryText)
                        }
                        if suggestion.option.walks[index].bike != nil {
                            Image(systemName: "bicycle")
                            if suggestion.option.bikeOnly { Text("YouBike") }
                            if suggestion.option.rides.indices.contains(index) {
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(MapChrome.secondaryText)
                            }
                        }
                        if suggestion.option.rides.indices.contains(index) {
                            let ride = suggestion.option.rides[index]
                            RouteBadge(name: ride.route.mode == .bus ? ride.route.localizedName : ride.route.lineCode,
                                tintName: ride.route.name, compact: true)
                        }
                    }
                }.liveFont(.caption, weight: .semibold).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { model.acceptJourneySuggestion() } label: {
                Text(AppText.text("改走")).liveFont(.subheadline, weight: .semibold)
                    .padding(.horizontal, 14).frame(minHeight: 44)
            }.buttonStyle(MapActionStyle()).accessibilityIdentifier("journey-alternative-accept")
            Button { model.dismissJourneySuggestion() } label: {
                Image(systemName: "xmark").liveFont(.subheadline, weight: .semibold).frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(MapChrome.secondaryText)
                .accessibilityLabel(AppText.text("保留目前路線"))
                .accessibilityIdentifier("journey-alternative-dismiss")
        }.padding(.leading, 16).padding(.trailing, 5).padding(.vertical, 10)
            .phoneGlass(in: live.shape(.panel))
    }
}

struct JourneyGuideCard: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let showJourney: () -> Void
    @State private var showRideStops = false
    @State private var chooseVehicle = false
    /// The step on screen before the latest change, so a step forward rises into place and
    /// a step back ("返回等車") settles from above.
    @State private var shownStepIndex = 0
    @Namespace private var stageSpace
    /// Changes only when the card moves to another stage or another route.
    private var stageKey: String { (planner.selectedID ?? "") + ":" + String(planner.stepIndex) }
    private var stageTransition: AnyTransition {
        let rise: CGFloat = planner.stepIndex >= shownStepIndex ? 10 : -10
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: rise)), removal: .opacity)
    }
    var body: some View {
        if let option = planner.selected {
            // The header stays in place for the whole trip; only the stage below it changes,
            // and the actions shared by consecutive stages move instead of fading.
            VStack(alignment: .leading, spacing: planner.boardingRideIndex != nil ? 10 : 12) {
                JourneyDockHeader(model: model, planner: planner, showJourney: showJourney)
                VStack(alignment: .leading, spacing: 12) {
                    if planner.boardingRideIndex != nil {
                        JourneyWaitingStage(model: model, planner: planner)
                    } else if planner.arrived {
                        Button { model.finishJourney() } label: {
                            Text(live.text("完成")).liveFont(.body, weight: .bold).frame(maxWidth: .infinity, minHeight: 50)
                        }.buttonStyle(MapActionStyle(prominent: true)).tripStageMatch("dock-primary")
                    } else if case .ride(let index) = planner.currentStep {
                        let ride = option.rides[index]
                        HStack(spacing: 8) {
                            if ride.route.mode != .bus {
                                TimelineView(.periodic(from:.now,by:1)) { timeline in
                                    MetroOnboardSummary(model:model,ride:ride,date:timeline.date,compact:true)
                                }
                            } else {
                            Button { chooseVehicle = true } label: {
                                Label(model.onboardPlate(for: ride) ?? AppText.text("選擇搭乘車牌"), systemImage: "bus")
                                    .liveFont(.subheadline, weight: .semibold).monospaced().lineLimit(1).minimumScaleFactor(0.8)
                                    .padding(.horizontal, 14).frame(minHeight: 40)
                            }.buttonStyle(MapActionStyle()).accessibilityIdentifier("journey-onboard-vehicle")
                            if let bus = model.onboardVehicle(for: ride) {
                                Button { model.trackApproachingVehicle(bus) } label: {
                                    Image(systemName: "scope").liveFont(.body, weight: .semibold).frame(width: 40, height: 40)
                                }.buttonStyle(MapActionStyle()).accessibilityLabel(AppText.text("追蹤 ") + bus.plate)
                            }
                            }
                            Spacer(minLength: 0)
                            // Alighting reminder (Pro): a filled bell while it will notify before the stop.
                            Button { model.toggleAlightReminder() } label: {
                                Image(systemName: model.alightReminderActive ? "bell.badge.fill" : model.purchases.hasPro ? "bell.slash" : "bell")
                                    .liveFont(.body, weight: .semibold).frame(width: 40, height: 40)
                            }.buttonStyle(MapActionStyle())
                                .accessibilityLabel(model.alightReminderActive ? AppText.text("關閉下車提醒") : AppText.text("下車提醒"))
                                .accessibilityValue(model.alightReminderStatus)
                                .accessibilityIdentifier("journey-alight-reminder")
                            // Icon-sized like the bell beside it, so the plate never has to shrink.
                            Button { showRideStops = true } label: {
                                // Stops joined by a line, distinct from the itinerary list in the header.
                                Image(systemName: "point.3.filled.connected.trianglepath.dotted").liveFont(.body, weight: .semibold).frame(width: 40, height: 40)
                            }
                            .buttonStyle(MapActionStyle(tint: Color.primary))
                            .accessibilityLabel(ride.route.mode == .bus ? AppText.text("沿途站牌") : AppText.text("沿線車站"))
                            .accessibilityIdentifier("journey-ride-stops")
                        }
                        if model.alightReminderState == .needsPermission {
                            Button { model.requestAlightReminderAccess() } label: {
                                Label(model.alightReminderStatus, systemImage: "bell.badge")
                                    .liveFont(.caption, weight: .semibold).frame(minHeight: 40)
                            }.buttonStyle(MapActionStyle(tint: MapChrome.caution))
                                .accessibilityIdentifier("journey-reminder-permission")
                        }
                        if option.rides.indices.contains(index + 1) {
                            let next = option.rides[index + 1]
                            Text(AppText.text("接著轉搭 %@ · %@", next.route.localizedName, next.boarding.localizedName)).liveFont(.caption).foregroundStyle(MapChrome.secondaryText).lineLimit(2)
                        }
                        HStack(spacing: 12) {
                            Button { model.returnToWaiting() } label: {
                                Text(live.text("返回等車")).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(MapActionStyle(tint: Color.primary)).tripStageMatch("dock-secondary")
                            Button { model.alight() } label: {
                                Text(live.text("已下車")).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(MapActionStyle(prominent: true)).tripStageMatch("dock-primary")
                                .accessibilityIdentifier("journey-alight")
                        }.liveFont(.body, weight: .semibold)
                    } else {
                        let index: Int = { if case .walk(let value) = planner.currentStep { return value }; return 0 }()
                        let cycling = option.walks.indices.contains(index) && option.walks[index].bike != nil
                        if cycling, let instruction = planner.cyclingInstruction(at: index) {
                            Text(instruction).liveFont(.subheadline, weight: .semibold)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("cycling-live-instruction")
                        }
                        if option.walks.indices.contains(index) {
                            Text(planner.walkingStatus(at: index) ?? option.walks[index].timeLabel).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText).accessibilityIdentifier("walking-live-status")
                        }
                        if cycling, let bike = option.walks[index].bike {
                            JourneyBikeStations(model: model, bike: bike, index: index, compact: true)
                            BikeStationAlert(model: model, planner: planner)
                        }
                        HStack(spacing: 12) {
                            Button { if !planner.started { planner.begin() }; model.showWalkOnMap(index) } label: {
                                Label(cycling ? live.text("看騎乘路線") : live.text("看步行路線"),
                                      systemImage: cycling ? "bicycle" : "figure.walk")
                                    .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(MapActionStyle()).tripStageMatch("dock-secondary").accessibilityHint(AppText.text("在目前地圖查看步行路線"))
                            Button { if !planner.started { planner.begin() }; planner.advance() } label: {
                                Text(live.text("已抵達")).lineLimit(1).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(MapActionStyle(prominent: true)).tripStageMatch("dock-primary")
                                .accessibilityIdentifier("journey-arrive")
                        }.liveFont(.body, weight: .semibold)
                    }
                }
                .id(stageKey)
                .transition(stageTransition)
            }
            .journeyDockSurface()
            .environment(\.tripStageNamespace, stageSpace)
            .smoothChanges(planner.currentStep)
            .smoothChanges(model.language)
            .onChange(of: planner.stepIndex, initial: true) { _, step in shownStepIndex = step }
            .sheet(isPresented: $showRideStops) {
                if let ride = planner.activeRide { OnboardStopsView(model: model, ride: ride) }
            }
            .sheet(isPresented: $chooseVehicle) {
                if let ride = planner.activeRide { BoardedVehiclePicker(model: model, ride: ride) }
            }
        }
    }
}

/// The Apple Maps style instruction at the top of the map: what to do now in
/// large type, with the following step in a slim strip underneath.
struct JourneyInstructionBanner: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    @Namespace private var stageSpace
    var body: some View {
        if let option = planner.selected {
            Group {
                // The leading badge or symbol and the main figure stand for the same things in
                // every stage, so they move to their new place while the wording fades over.
                if let index = planner.boardingRideIndex, option.rides.indices.contains(index) {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        WaitingBannerContent(model: model, ride: option.rides[index], date: timeline.date)
                    }
                } else if case .ride(let index) = planner.currentStep, option.rides.indices.contains(index) {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        RidingBannerContent(model: model, ride: option.rides[index], date: timeline.date)
                    }
                } else {
                    WalkingBannerContent(planner: planner)
                }
            }
            .environment(\.tripStageNamespace, stageSpace)
            .modifier(InstructionBannerSurface())
            .smoothChanges(planner.currentStep)
            .smoothChanges(planner.selectedID)
        }
    }
}

private struct TripStageNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
extension EnvironmentValues {
    /// Shared by the views of one trip card or banner across its stages.
    var tripStageNamespace: Namespace.ID? {
        get { self[TripStageNamespaceKey.self] }
        set { self[TripStageNamespaceKey.self] = newValue }
    }
}
private struct TripStageMatch: ViewModifier {
    @Environment(\.tripStageNamespace) private var namespace
    let id: String
    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.matchedGeometryEffect(id: id, in: namespace) } else { content }
    }
}
private extension View {
    /// Marks the view that stands for `id` in the current trip stage; the next stage's view
    /// with the same id takes over its frame instead of appearing from nowhere.
    func tripStageMatch(_ id: String) -> some View { modifier(TripStageMatch(id: id)) }
}

struct InstructionBannerSurface: ViewModifier {
    @Environment(\.liveSettings) private var live
    func body(content: Content) -> some View {
        let shape = live.shape(.card)
        content.foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 0.97) : UIColor(white: 0.11, alpha: 0.95) })))
            .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6) }
            .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
    }
}

struct BannerStrip<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.6)
            HStack(spacing: 8) { content }
                .liveFont(.subheadline).foregroundStyle(Color.white.opacity(0.8))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WaitingBannerContent: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    /// The ride whose bus already announced itself, so an estimate that dips under a
    /// minute, refreshes back over it and dips again taps only once.
    @State private var announcedRide: String?
    var body: some View {
        let guide = BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: date)
        let boarding = model.boardingInformation(ride, at: date)
        let access = model.planner.accessInstruction(at: model.planner.boardingRideIndex ?? 0, date: date)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                RouteBadge(name: ride.route.mode == .bus ? ride.route.localizedName : ride.route.lineCode, tintName: ride.route.name).tripStageMatch("banner-lead")
                    .accessibilityIdentifier("boarding-route")
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.text("往 ") + ride.route.localizedDestination(direction: ride.direction))
                        .liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                    BannerTitle(text: access ?? (live.text("上車 · ") + ride.boarding.localizedName))
                        .accessibilityIdentifier("journey-current-instruction")
                    if live.language == .english { Text(ride.boarding.name).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)) }
                    if ride.route.displayName != ride.route.name,
                       model.metadata.routeIDs(serving: ride).filter({ model.metadata.routes[$0] != nil }).count <= 1 {
                        Text(ride.route.localizedDisplayName).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    let wait = ride.route.mode == .bus ? boarding.label : model.metroWaitLabel(ride, at: date)
                    Text(wait).liveFont(.title, weight: .bold, design: .rounded)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                        .liveNumericText(wait, countsDown: true)
                        .accessibilityIdentifier("boarding-official-arrival")
                    Text(ride.route.mode != .bus ? model.metroWaitSource(ride, at: date) : boarding.source)
                        .liveFont(.caption, weight: .semibold).lineLimit(2).minimumScaleFactor(0.9)
                        .foregroundStyle((guide.estimateSeconds ?? -1) >= 0 ? Color(liveHex: "#6EE7A0") : Color.white.opacity(0.72))
                }.frame(width: live.language == .english ? 112 : 98, alignment: .trailing).tripStageMatch("banner-figure")
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            BannerStrip {
                Image(systemName: "arrow.down").font(.caption.weight(.bold))
                // The header already names the line and direction; repeating them here was
                // truncated ("接著搭 文湖線 · 往…"). Where to get off is the useful next fact.
                Text(AppText.text("在「%@」下車", ride.alighting.localizedName)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Text(AppText.text("搭乘 %@ 站 · 約 %@ 分鐘", ride.stopCount, max(1, Int(ceil(model.plannedRideTime(ride, at: date).seconds / 60)))))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: announcedRide) { _, new in new != nil }
        .onChange(of: ride.route.mode == .bus && guide.arrivingSoon) { _, soon in
            if soon { announcedRide = ride.id }
        }
    }
}

/// A stop name in the navigation banner stays on one line, stepping down in size as needed,
/// so a name is never broken in the middle across two lines.
private struct BannerTitle: View {
    let text: String
    var body: some View {
        Text(text).liveFont(.title3, weight: .bold).lineLimit(2).minimumScaleFactor(0.9)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RidingBannerContent: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    var body: some View {
        if ride.route.mode != .bus {
            let remaining = model.metroRemaining(ride, at: date)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    RouteBadge(name: ride.route.lineCode, tintName: ride.route.name).tripStageMatch("banner-lead")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppText.text("往 %@", ride.route.localizedDestination(direction: ride.direction))).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72))
                        BannerTitle(text: AppText.text("下車 · ") + ride.alighting.localizedName)
                        if live.language == .english { Text(ride.alighting.name).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)) }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        let minutes = max(0, Int(ceil(remaining.seconds / 60)))
                        Text(AppText.minutes(minutes)).liveFont(.title, weight: .bold).monospacedDigit()
                            .liveNumericText(minutes, countsDown: true)
                        Text(AppText.remainingStops(remaining.stops.count)).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72))
                    }.tripStageMatch("banner-figure")
                }.padding(.horizontal, 16).padding(.vertical, 13)
                BannerStrip {
                    Image(systemName: "tram.fill")
                    Text(remaining.stops.first.map { AppText.text("下一站 · ") + $0.localizedName } ?? AppText.text("準備下車"))
                    Spacer()
                    Text(model.metroPositionLabel(remaining.source, detailed: false)).liveFont(.caption)
                }
            }
        } else {
        let bus = model.onboardVehicle(for: ride)
        let journey = bus.flatMap { model.metadata.journey(routeID: $0.routeID, direction: $0.direction) }
        let progress = bus.flatMap { vehicle in journey?.progress(stopID: ride.alighting.id, vehicle: vehicle, at: date) }
        let stops = model.onboardStops(for: ride, at: date)
        let next = stops.first
        let alightNext = next?.id == ride.alighting.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                RouteBadge(name: ride.route.mode == .bus ? ride.route.localizedName : ride.route.lineCode, tintName: ride.route.name).tripStageMatch("banner-lead")
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.text("往 ") + ride.route.localizedDestination(direction: ride.direction))
                        .liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                    // Same "action · stop" form as the boarding banner.
                    BannerTitle(text: (progress?.distance ?? 0) < -20 ? AppText.text("已通過「%@」", ride.alighting.localizedName) : live.text("下車 · ") + ride.alighting.localizedName)
                    if live.language == .english { Text(ride.alighting.name).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)) }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    let alighting = model.onboardStopTimeLabel(ride, stopID:ride.alighting.id,at:date)
                    Text(alighting)
                        .liveFont(.title3, weight: .bold).monospacedDigit().lineLimit(2).minimumScaleFactor(0.7)
                        .multilineTextAlignment(.trailing).liveNumericText(alighting, countsDown: true)
                    if let count = stops.firstIndex(where: { $0.id == ride.alighting.id }) {
                        Text(AppText.remainingStops(count+1)).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72))
                            .liveNumericText(count, countsDown: true)
                    }
                }.frame(maxWidth: live.language == .english ? 120 : 112, alignment: .trailing).tripStageMatch("banner-figure")
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .accessibilityElement(children: .combine).accessibilityIdentifier("journey-alighting-time")
            BannerStrip {
                if let next {
                    if (model.onboardProgress?.isFresh(at:date) == true && model.onboardProgress?.source == .phone) || bus.map({ model.isRiderAnchored($0) }) == true {
                        // The bus follows the rider's own fix, so its position is live rather than delayed.
                        Image(systemName: "location.fill").font(.caption2.weight(.bold)).foregroundStyle(Color(liveHex: "#6EA8FF"))
                            .frame(width: 12).accessibilityLabel(AppText.text("依你的定位即時更新"))
                    } else {
                        Circle().fill(Color(liveHex: "#6EA8FF")).frame(width: 8, height: 8).frame(width: 12)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text((next.id == ride.alighting.id ? AppText.text("下一站下車 · ") : AppText.text("下一站 · ")) + next.localizedName).lineLimit(1)
                            .fontWeight(alightNext ? .semibold : nil)
                            .foregroundStyle(alightNext ? Color(liveHex: "#FFD60A") : Color.white.opacity(0.8))
                        if live.language == .english { Text(next.name).liveFont(.caption) }
                    }
                    Spacer(minLength: 4)
                    Text(model.onboardStopTimeLabel(ride, stopID:next.id,at:date) + " · " + AppText.remainingStops(1))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                } else {
                    Image(systemName: "bus").font(.caption.weight(.semibold))
                    Text(AppText.text("準備下車")).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("journey-next-stop")
        }
        .sensoryFeedback(.warning, trigger: alightNext) { _, new in new }
        }
    }
}

struct MetroBoardingRows: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    /// During navigation the banner already states where the time comes from.
    var showsSource = true
    private var arrivals: [MetroArrival] {
        (model.metroRealtime?.arrivals ?? []).filter { $0.stationID == ride.boarding.stationID && $0.remaining(at: date) != nil && model.metadata.metro.canServe(ride, patternID: $0.patternID, direction: $0.direction, destinationStationID: $0.destinationStationID) }
            .sorted { ($0.remaining(at: date) ?? .max) < ($1.remaining(at: date) ?? .max) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if arrivals.isEmpty {
                HStack {
                    Image(systemName: "tram.fill").foregroundStyle(MapChrome.secondaryText)
                    Text(AppText.text("下班列車")).liveFont(.subheadline, weight: .semibold)
                    Spacer()
                    let wait = model.metroWaitLabel(ride, at: date)
                    Text(wait).liveFont(.subheadline, weight: .bold).monospacedDigit().liveNumericText(wait, countsDown: true)
                    if let tracked = model.nextTrackedTrain(routeID: ride.route.id, direction: ride.direction, boardingStationID: ride.boarding.stationID,
                                                            alightingStationID: ride.alighting.stationID, at: date) {
                        Button { model.toggleTrainTracking(tracked.train.id) } label: {
                            Label(model.selectedTrainID == tracked.train.id ? AppText.text("追蹤中") : AppText.text("追蹤"), systemImage: "scope")
                                .liveFont(.caption, weight: .semibold).padding(8)
                        }.buttonStyle(MapActionStyle()).accessibilityIdentifier("metro-track-estimated")
                            .accessibilityHint(model.selectedTrainID == tracked.train.id ? AppText.text("停止追蹤") : "")
                    }
                }
                if showsSource { Text(model.metroWaitSource(ride, at: date)).liveFont(.caption).foregroundStyle(MapChrome.secondaryText) }
            } else {
                ForEach(Array(arrivals.prefix(3).enumerated()), id: \.offset) { index, arrival in
                    HStack {
                        Text(index == 0 ? AppText.text("下班列車") : AppText.text("後續班次")).liveFont(.subheadline)
                        Spacer()
                        let countdown = MetroCountdown.label(arrival.remaining(at: date))
                        Text(countdown).liveFont(.subheadline, weight: .semibold).monospacedDigit().liveNumericText(countdown, countsDown: true)
                        if let id = arrival.trainID, model.metroTrain(id) != nil {
                            Button { model.toggleTrainTracking(id) } label: {
                                Label(model.selectedTrainID == id ? AppText.text("追蹤中") : AppText.text("追蹤"), systemImage: "scope")
                                    .liveFont(.caption, weight: .semibold).padding(8)
                            }.buttonStyle(MapActionStyle()).accessibilityIdentifier("metro-track-arrival-" + id)
                                .accessibilityHint(model.selectedTrainID == id ? AppText.text("停止追蹤") : "")
                        }
                    }
                }
                if showsSource { Text(AppText.text("官方到站時間")).liveFont(.caption).foregroundStyle(MapChrome.secondaryText) }
            }
        }.padding(.vertical, 6).accessibilityElement(children: .contain).accessibilityIdentifier("metro-boarding-arrivals")
    }
}

private struct MetroOnboardSummary: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    var compact = false
    var body: some View {
        let remaining = model.metroRemaining(ride, at: date)
        VStack(alignment: .leading, spacing: 6) {
            if !compact { HStack {
                Text(AppText.text("在「%@」下車", ride.alighting.localizedName)).liveFont(.title3, weight: .bold)
                Spacer()
                let minutes = max(0, Int(ceil(remaining.seconds / 60)))
                Text(AppText.minutes(minutes)).liveFont(.title3, weight: .bold).monospacedDigit()
                    .liveNumericText(minutes, countsDown: true)
            } }
            HStack {
                Text(remaining.stops.first.map { AppText.text("下一站 · ") + $0.localizedName } ?? AppText.text("準備下車"))
                Spacer()
                if !compact { Text(AppText.remainingStops(remaining.stops.count)) }
            }.liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText)
            Text(model.metroPositionLabel(remaining.source, detailed: !compact))
                .liveFont(.caption).foregroundStyle(MapChrome.secondaryText)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("metro-onboard-summary")
    }
}

private struct WalkingBannerContent: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var planner: JourneyPlannerModel
    /// On a cycling leg the instruction changes as the rider fetches, rides and returns the bike.
    private var cyclingInstruction: String? {
        guard case .walk(let index) = planner.currentStep else { return nil }
        return planner.cyclingInstruction(at: index)
    }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: planner.arrived ? "checkmark.circle.fill" : cyclingInstruction != nil ? "bicycle" : "figure.walk")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(planner.arrived ? Color(liveHex: "#6EE7A0") : Color.white)
                .frame(width: 40).tripStageMatch("banner-lead")
            VStack(alignment: .leading, spacing: 2) {
                Text(planner.arrived ? live.text("已抵達") : cyclingInstruction
                     ?? AppText.text("走到「%@」", planner.destination?.localizedName ?? AppText.text("目的地")))
                    .liveFont(.title3, weight: .bold).lineLimit(2).minimumScaleFactor(0.8)
                if live.language == .english, let name = planner.destination?.name {
                    Text(name).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72))
                }
                // Leaving a metro station: name the exit that faces the destination.
                if !planner.arrived, let exit = planner.selected?.walks.last?.stationInstruction,
                   planner.selected?.rides.last.map({ $0.alighting.mode != .bus }) == true {
                    Label(exit, systemImage: "door.left.hand.open")
                        .liveFont(.subheadline, weight: .semibold).foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .accessibilityIdentifier("walking-metro-exit")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
    }
}
