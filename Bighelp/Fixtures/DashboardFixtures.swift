import Foundation

enum DashboardFixtureError: Error {
    case unavailable
}

struct DashboardFixtureSource: DashboardDataSource {
    let shouldFail: Bool
    let bighelpCards: [BighelpCardDocument]

    init(shouldFail: Bool = false, bighelpCards: [BighelpCardDocument] = []) {
        self.shouldFail = shouldFail
        self.bighelpCards = bighelpCards
    }

    func loadDashboard() async throws -> DashboardSnapshot {
        guard !shouldFail else {
            throw DashboardFixtureError.unavailable
        }

        return DashboardSnapshot(
            inbox: bighelpCards.enumerated().map { index, card in
                DashboardInboxItem(
                    id: "loopdy-card-gallery-\(index)",
                    title: card.title,
                    detail: card.spokenSummary,
                    agentName: "Juno",
                    status: "Demo data",
                    bighelpCard: card,
                    createdAt: Date(timeIntervalSince1970: 1_788_350_400 + Double(index))
                )
            } + [
                DashboardInboxItem(
                    id: "inbox-finance-payment",
                    title: "Vendor payment is ready for review",
                    detail: "Northstar Studio invoice is due Friday.",
                    agentName: "Avery",
                    status: "Ready"
                ),
                DashboardInboxItem(
                    id: "inbox-travel-itinerary",
                    title: "Your Seattle itinerary is ready",
                    detail: "Three quiet hotel options fit the schedule.",
                    agentName: "Mina",
                    status: "Updated"
                ),
                DashboardInboxItem(
                    id: "inbox-home-delivery",
                    title: "Delivery window confirmed",
                    detail: "The home team confirmed Tuesday afternoon.",
                    agentName: "Jordan",
                    status: "Confirmed"
                )
            ],
            attentionItems: ProcessInfo.processInfo.arguments.contains("-demo-needs-you")
                ? [
                    DashboardAttentionItem(
                        id: "attention-payment",
                        title: "Allow Avery to push 2 commits to remote?",
                        detail: "git push origin feat/q4-tax-export · Pushes branch to GitHub without opening a PR.",
                        urgency: .important,
                        approvalID: "approval-demo-1",
                        sessionID: "demo-finance",
                        agentID: "finance",
                        interaction: .approval(
                            DashboardApprovalRequest(
                                eventID: "attention-payment",
                                approvalID: "approval-demo-1",
                                allowedDecisions: [.once, .session, .deny],
                                expiresAt: .distantFuture
                            )
                        ),
                        createdAt: Date()
                    ),
                    DashboardAttentionItem(
                        id: "attention-calendar",
                        title: "Found 3 nonstop Tokyo flights under $780. Which fare should I hold?",
                        detail: "Holding a fare is free for 24 hours; nothing is charged.",
                        urgency: .needsReview,
                        sessionID: "demo-travel",
                        agentID: "travel",
                        interaction: .clarification(
                            DashboardClarificationRequest(
                                eventID: "attention-calendar",
                                requestID: "clarify-demo-1",
                                sessionID: "demo-travel",
                                question: "Found 3 nonstop Tokyo flights under $780. Which fare should I hold?",
                                choices: [
                                    "JAL Economy Main · $640",
                                    "ANA Economy Flex · $715",
                                    "Keep watching prices",
                                ],
                                allowsCustomResponse: true,
                                isMultiSelect: false,
                                expiresAt: .distantFuture
                            )
                        ),
                        createdAt: Date()
                    ),
                ]
                : [
                    DashboardAttentionItem(
                        id: "attention-payment",
                        title: "Approve Northstar Studio payment",
                        detail: "$2,480 is due Friday to keep the project on schedule.",
                        urgency: .important
                    ),
                    DashboardAttentionItem(
                        id: "attention-calendar",
                        title: "Review tomorrow's focus plan",
                        detail: "Two overlapping meetings need a decision.",
                        urgency: .needsReview
                    ),
                ],
            completedItems: [
                DashboardCompletion(
                    id: "completed-weekly-brief",
                    title: "Weekly briefing prepared",
                    detail: "Avery summarized priorities, spending, and follow-ups.",
                    completedLabel: "Completed 18 min ago"
                ),
                DashboardCompletion(
                    id: "completed-grocery-list",
                    title: "Grocery list organized",
                    detail: "Jordan grouped staples for this week's meals.",
                    completedLabel: "Completed 42 min ago"
                )
            ],
            agents: [
                DashboardAgent(
                    id: "finance",
                    initials: "AP",
                    name: "Avery Park",
                    role: "Finance agent",
                    availability: "Available now"
                ),
                DashboardAgent(
                    id: "travel",
                    initials: "MS",
                    name: "Mina Shah",
                    role: "Travel agent",
                    availability: "Working on itinerary"
                ),
                DashboardAgent(
                    id: "home",
                    initials: "JL",
                    name: "Jordan Lee",
                    role: "Home agent",
                    availability: "Available now"
                )
            ]
        )
    }

    func dismissDashboardEvent(id: String) async throws {}

    func dismissDashboardEvents(types: [String], createdBefore: Date) async throws {}
}
