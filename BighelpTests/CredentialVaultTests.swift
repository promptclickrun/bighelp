import Foundation
import Testing
@testable import Bighelp

@MainActor
struct CredentialVaultTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("https://Example.com/login?next=1", "https://example.com"),
        ("http://192.168.1.20:8080/admin", "http://192.168.1.20:8080"),
        (" shop.example.org ", "https://shop.example.org"),
        ("https://example.com:443/pay", "https://example.com"),
    ])
    func aTypedSiteBecomesItsOrigin(typed: String, origin: String) {
        #expect(CredentialVault.origin(from: typed) == origin)
    }

    @Test(arguments: ["", "not a site", "javascript:alert(1)", "ftp://example.com", "https://user:pw@example.com", "localhost.x y"])
    func somethingThatIsntASiteIsRefused(typed: String) {
        #expect(CredentialVault.origin(from: typed) == nil)
    }

    @Test func aLoginIsSentTheWayHermesStoresIt() throws {
        let requests = try CredentialVault.requests(for: .login(sites: ["example.com/login"], identifier: " sam@example.com ",
            password: "made-up-pass", authenticatorKey: "JBSWY3DPEHPK3PXP")).get()
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request["kind"] == .string("login"))
        #expect(request["label"] == .string("example.com"), "Named for the site unless given a name")
        #expect(request["origin"] == .string("https://example.com"))
        #expect(request["secret"] == .object(["identifier_type": .string("email"), "identifier": .string("sam@example.com"),
                                             "password": .string("made-up-pass"), "otp_secret": .string("JBSWY3DPEHPK3PXP")]))
    }

    @Test func aCardKeepsOnlyItsLastDigitsInTheLabel() throws {
        let request = try #require(try CredentialVault.requests(for: .card(name: "Sam Example", number: "4242 4242 4242 4242",
            month: "3", year: "29", securityCode: "123", postalCode: "")).get().first)
        #expect(request["label"] == .string("Card ending 4242"))
        #expect(request["origin"] == nil)
        #expect(request["secret"]?.object?["card_number"] == .string("4242424242424242"))
        #expect(request["secret"]?.object?["exp_month"] == .string("03"))
        #expect(request["secret"]?.object?["exp_year"] == .string("2029"))
        #expect(request["secret"]?.object?["billing_postal_code"] == nil)
    }

    /// Hermes fills a card or address only on a site it's linked to, one site per saved copy.
    @Test func aNamedCardIsSavedOncePerSite() throws {
        let requests = try CredentialVault.requests(for: .card(label: " Everyday Visa ",
            sites: ["shop.example.org", "", "https://parts.example.net/checkout", "SHOP.example.org"],
            name: "", number: "4242424242424242", month: "12", year: "2031", securityCode: "123", postalCode: "")).get()
        #expect(requests.map { $0["origin"] } == [.string("https://shop.example.org"), .string("https://parts.example.net")])
        #expect(requests.allSatisfy { $0["label"] == .string("Everyday Visa ending 4242") })
        let address = try CredentialVault.requests(for: .address(label: "", sites: ["shop.example.org"], line1: "1 Main St",
            line2: "", city: "Springfield", state: "", postalCode: "00000", country: "US")).get()
        #expect(address.first?["label"] == .string("Address"))
        #expect(address.first?["origin"] == .string("https://shop.example.org"))
        let login = try CredentialVault.requests(for: .login(label: "Work email", sites: ["mail.example.com", "example.com"],
            identifier: "sam", password: "made-up-pass", authenticatorKey: "")).get()
        #expect(login.count == 2 && login.allSatisfy { $0["label"] == .string("Work email") })
    }

    @Test func incompleteItemsSayWhatsMissing() {
        #expect(CredentialVault.requests(for: .login(sites: ["example.com"], identifier: "", password: "x",
                                                     authenticatorKey: "")).failure == .identifier)
        #expect(CredentialVault.requests(for: .login(sites: [""], identifier: "sam", password: "x",
                                                     authenticatorKey: "")).failure == .site, "A login needs a site")
        #expect(CredentialVault.requests(for: .card(sites: ["not a site"], name: "", number: "4242424242424242",
            month: "1", year: "2030", securityCode: "123", postalCode: "")).failure == .site)
        #expect(CredentialVault.requests(for: .card(name: "", number: "4242", month: "1", year: "2030",
                                                    securityCode: "123", postalCode: "")).failure == .cardNumber)
        #expect(CredentialVault.requests(for: .address(label: "Home", line1: "1 Main St", line2: "", city: "",
            state: "", postalCode: "00000", country: "US")).failure == .address)
    }

    @Test func copiesOfOneItemShowAsOneWithItsSites() async {
        let model = CredentialVaultModel(service: DemoCredentialVaultService(),
                                         agents: [.init(id: "default", name: "Default")], agentID: "default")
        await model.load()
        let cards = model.groups.filter { $0.kind == .payment }
        let everyday = cards.first { $0.label == "Everyday Visa ending 4242" }
        #expect(everyday?.sites == ["shop.example.org", "parts.example.net"])
        #expect(everyday?.typedLabel == "Everyday Visa")
        #expect(everyday?.isUsable == true)
        let unlinked = cards.first { $0.label == "Card ending 1881" }
        #expect(unlinked?.isUsable == false, "A card with no site can't be filled anywhere")
        #expect(unlinked?.typedLabel == "")
    }

    @Test func editingReplacesTheOldCopiesOnlyOnceTheNewOnesAreSaved() async throws {
        let model = CredentialVaultModel(service: DemoCredentialVaultService(),
                                         agents: [.init(id: "default", name: "Default")], agentID: "default")
        await model.load()
        let old = try #require(model.groups.first { $0.label == "Card ending 1881" })
        let saved = await model.save(.card(label: "Travel card", sites: ["air.example.com"], name: "",
            number: "5555555555551881", month: "4", year: "2030", securityCode: "321", postalCode: ""), replacing: old)
        #expect(saved)
        #expect(!model.items.contains { item in old.items.contains { $0.id == item.id } })
        let renamed = model.groups.first { $0.label == "Travel card ending 1881" }
        #expect(renamed?.sites == ["air.example.com"])

        let before = model.items.count
        let refused = await model.save(.card(label: "Broken", name: "", number: "12", month: "4", year: "2030",
                                             securityCode: "321", postalCode: ""), replacing: renamed)
        #expect(!refused)
        #expect(model.items.count == before, "A failed edit keeps what was there")
    }

    @Test func savingAddsTheItemForTheChosenAgentAndListsIt() async {
        let service = RecordingVault()
        let model = CredentialVaultModel(service: service, agents: [.init(id: "default", name: "Default"),
                                                                    .init(id: "juniper", name: "Juniper")],
                                         agentID: "juniper")
        await model.load()
        #expect(model.state == .ready)
        let saved = await model.save(.login(sites: ["example.com"], identifier: "sam", password: "made-up-pass",
                                            authenticatorKey: ""))
        #expect(saved)
        #expect(model.items.map(\.label).contains("example.com"))
        #expect(model.items.first { $0.label == "example.com" && $0.identifier == "sam" }?.generatesCodes == false)
        let add = service.calls.first { $0.method == "vault.add" }
        #expect(add?.params["profile"] == .string("juniper"))
        #expect(add?.params["secret"]?.object?["password"] == .string("made-up-pass"))
        #expect(model.message == nil)
    }

    @Test func websitesListWhatAnAgentCanUseThereAndTheWalletHoldsEachCardOnce() async throws {
        let model = await demoVault()
        #expect(model.sites.map(\.name) == ["example.com", "parts.example.net", "shop.example.org"])
        let shop = try #require(model.site("https://shop.example.org"))
        #expect(shop.kinds == [.payment, .address])
        #expect(shop.hasLocalItems)
        #expect(model.wallet.map(\.label) == ["Card ending 1881", "Everyday Visa ending 4242", "Home"],
                "Cards then addresses, each once however many websites use it")
        #expect(model.wallet.first { $0.label == "Home" }?.sites == ["shop.example.org", "parts.example.net"])
    }

    @Test func oneSaveStoresEachPickedPartAndCopiesASavedAddressInsteadOfTypingIt() async throws {
        let service = RecordingVault()
        let model = await demoVault(service)
        let home = try #require(model.wallet.first { $0.label == "Home" })
        let add = CredentialVaultAddModel(vault: model, parts: [.login, .card, .address])
        #expect(add.addressChoice == .saved(home.id), "A saved address is picked to start with")
        add.sites = ["store.example.com/checkout"]
        add.cardChoice = .new
        add.typing.identifier = "sam@example.com"
        add.typing.password = "made-up-pass"
        add.typing.cardNumber = "4242 4242 4242 4242"
        add.typing.month = "8"
        add.typing.year = "2030"
        add.typing.securityCode = "123"

        #expect(await add.save())
        let adds = service.calls.filter { $0.method == "vault.add" }
        #expect(adds.map { $0.params["kind"] } == [.string("login"), .string("payment")])
        #expect(adds.allSatisfy { $0.params["origin"] == .string("https://store.example.com") })
        #expect(adds.allSatisfy { $0.params["profile"] == .string("default") })
        let link = try #require(service.links.first)
        #expect(service.links.count == 1)
        #expect(link["profile"] == .string("default"))
        #expect(link["item_ids"] == .array([.string(home.firstItemID)]))
        #expect(link["origins"] == .array([.string("https://store.example.com")]))
        #expect(link.keys.sorted() == ["item_ids", "origins", "profile"], "No secret goes with a copy")
        #expect(model.site("https://store.example.com")?.kinds == [.login, .payment, .address])
        #expect(add.typing.password.isEmpty && add.typing.cardNumber.isEmpty, "Secrets go once they're saved")
    }

    @Test func aPartThatFailsStaysAndTryingAgainSendsOnlyThatPart() async {
        let service = RecordingVault()
        service.failsNextAdd = "payment"
        let model = await demoVault(service)
        let add = CredentialVaultAddModel(vault: model, site: "https://store.example.com", parts: [.login, .card])
        add.cardChoice = .new
        add.typing.identifier = "sam"
        add.typing.password = "made-up-pass"
        add.typing.cardNumber = "4242424242424242"
        add.typing.month = "8"
        add.typing.year = "30"
        add.typing.securityCode = "123"

        #expect(await add.save() == false)
        #expect(add.saved == [.login])
        #expect(add.failed == .card)
        #expect(add.message?.contains("card didn't save") == true)
        #expect(add.typing.cardNumber == "4242424242424242", "What was typed stays to try again")
        #expect(add.typing.password.isEmpty, "The saved login's password goes at once")
        #expect(add.saveTitle == "Save the Card")

        #expect(await add.save())
        let logins = service.calls.filter { $0.method == "vault.add" && $0.params["kind"] == .string("login") }
        #expect(logins.count == 1, "The login isn't sent twice")
        #expect(model.site("https://store.example.com")?.kinds == [.login, .payment])
    }

    @Test func nothingIsSentWhileAPartIsIncomplete() async {
        let service = RecordingVault()
        let model = await demoVault(service)
        let add = CredentialVaultAddModel(vault: model, site: "store.example.com", parts: [.login, .card])
        add.cardChoice = .new
        add.typing.identifier = "sam"
        add.typing.password = "made-up-pass"
        add.typing.cardNumber = "12"

        #expect(await add.save() == false)
        #expect(add.failed == .card)
        #expect(add.message == CredentialVault.EntryProblem.cardNumber.message)
        #expect(!service.calls.contains { $0.method == "vault.add" }, "The login waits for the card to be right")
        #expect(add.saved.isEmpty)
    }

    @Test func withoutTheCopyRouteSavedCardsArentOffered() async {
        let service = RecordingVault()
        service.demo.linksItems = false
        let model = await demoVault(service)
        #expect(!model.canLink)
        let add = CredentialVaultAddModel(vault: model, parts: [.card, .address])
        #expect(add.savedCards.isEmpty && add.savedAddresses.isEmpty)
        #expect(add.cardChoice == .new && add.addressChoice == .new)
    }

    @Test func aSavedCardGoesOnAnotherWebsiteOnceAndItsCopyWithoutOneGoes() async throws {
        let service = RecordingVault()
        let model = await demoVault(service)
        let unlinked = try #require(model.groups.first { $0.label == "Card ending 1881" })
        #expect(await model.use(unlinked, on: "air.example.com"))
        let linked = try #require(model.group(unlinked.id))
        #expect(linked.origins == ["https://air.example.com"])
        #expect(linked.items.allSatisfy { $0.origin != nil }, "A copy no website can use is removed")

        let count = model.items.count
        #expect(await model.use(linked, on: "https://air.example.com/"))
        #expect(model.items.count == count)
        #expect(service.links.count == 1, "A website it's already on isn't asked for again")
        #expect(await model.use(linked, on: "not a site") == false)
        #expect(model.message == CredentialVault.EntryProblem.site.message)
    }

    @Test func aCopyThatCantBeMadeSaysWhy() async throws {
        let service = RecordingVault()
        let model = await demoVault(service)
        let unlinked = try #require(model.groups.first { $0.label == "Card ending 1881" })
        service.demo.linksItems = false
        #expect(await model.use(unlinked, on: "air.example.com") == false)
        #expect(model.message == CredentialVaultModel.linkFailure(WorkspaceClientError.unavailable(.unsupportedOperation)))
        #expect(model.group(unlinked.id)?.origins.isEmpty == true)
    }

    @Test func theWebsiteHermesWritesBackCountsHoweverItsSpelled() async throws {
        let service = RecordingVault()
        service.echoesOrigins = { $0.replacingOccurrences(of: "air.", with: "AIR.") + "/" }
        let model = await demoVault(service)
        let unlinked = try #require(model.groups.first { $0.label == "Card ending 1881" })
        #expect(await model.use(unlinked, on: "air.example.com"), "https://AIR.example.com/ is the website asked for")
    }

    @Test func aSavedChoiceThatsGoneIsTypedInstead() async throws {
        let model = await demoVault()
        let add = CredentialVaultAddModel(vault: model, site: "store.example.com", parts: [.card])
        guard case .saved(let id) = add.cardChoice, let card = model.group(id) else {
            Issue.record("A saved card starts picked")
            return
        }
        await model.remove(card)
        #expect(await add.save() == false)
        #expect(add.cardChoice == .new, "Its fields show again")
        #expect(add.message == CredentialVault.EntryProblem.cardNumber.message)
    }

    @Test func aCheckThatCantReachTheComputerKeepsWhatTheLastOneFound() async {
        let service = RecordingVault()
        let model = await demoVault(service)
        #expect(model.canLink)
        service.cantCheck = true
        await model.load()
        #expect(model.canLink, "A moment without the plugin isn't an old plugin")
    }

    @Test func aRemoveThatFailsSaysSo() async throws {
        let service = RecordingVault()
        let model = await demoVault(service)
        let parts = try #require(model.site("https://parts.example.net"))
        service.failsRemoves = true
        #expect(await model.remove(parts) == false)
        #expect(model.message != nil)
        #expect(model.site("https://parts.example.net") != nil)
    }

    @Test func stoppingOneWebsiteKeepsTheOthersAndTheLastOneStays() async throws {
        let model = await demoVault()
        let everyday = try #require(model.groups.first { $0.label == "Everyday Visa ending 4242" })
        await model.stop(everyday, on: "https://parts.example.net")
        let left = try #require(model.group(everyday.id))
        #expect(left.origins == ["https://shop.example.org"])
        await model.stop(left, on: "https://shop.example.org")
        #expect(model.group(everyday.id)?.origins == ["https://shop.example.org"], "Remove, which asks first, takes the last one")
    }

    @Test func removingAWebsiteRemovesOnlyItsOwnCopies() async throws {
        let model = await demoVault()
        let parts = try #require(model.site("https://parts.example.net"))
        await model.remove(parts)
        #expect(model.site("https://parts.example.net") == nil)
        #expect(model.wallet.first { $0.label == "Everyday Visa ending 4242" }?.sites == ["shop.example.org"])
        #expect(model.wallet.first { $0.label == "Home" }?.sites == ["shop.example.org"])
    }

    @Test func theCopyRouteIsThePluginsVaultLink() {
        #expect(DirectHermesNativePluginClient.responseBudget(.vaultLink)?.path == "/api/plugins/loopdy/native/vault/link")
        #expect(CredentialVault.linkFeature == "native-vault-link-v1")
    }

    @Test func anOlderHermesSaysToUpdate() async {
        let model = CredentialVaultModel(service: OlderHermes(), agents: [.init(id: "default", name: "Default")],
                                         agentID: "default")
        await model.load()
        #expect(model.state == .unsupported)
    }

    @Test func managersFromOtherSourcesCantBeRemovedHere() async {
        let model = CredentialVaultModel(service: DemoCredentialVaultService(),
                                         agents: [.init(id: "default", name: "Default")], agentID: "default")
        await model.load()
        let manager = try? #require(model.managers.first { $0.name == "onepassword" })
        #expect(manager?.unlocked == false)
        if let manager { #expect(await model.unlock(manager, password: "made-up-master")) }
        let borrowed = model.items.first { !$0.isLocal }
        #expect(borrowed?.source == "onepassword")
        if let borrowed { await model.remove(borrowed) }
        #expect(model.items.contains { $0.id == borrowed?.id })
        #expect(!model.managers.contains { $0.name == "bitwarden" }, "Managers that aren't installed stay hidden")
    }
}

@MainActor
struct CredentialVaultImportTests {
    @Test(arguments: [
        ("Apple Passwords", "Title,URL,Username,Password,Notes,OTPAuth\nNews,https://news.example.net/login,sam,pw1,,otpauth://totp/x?secret=JBSWY3DPEHPK3PXP"),
        ("Chrome", "name,url,username,password,note\nnews.example.net,https://news.example.net/,sam,pw1,"),
        ("Firefox", "\"url\",\"username\",\"password\",\"httpRealm\"\n\"https://news.example.net\",\"sam\",\"pw1\",\"\""),
        ("1Password", "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nNews,news.example.net,sam,pw1,,false,false,,"),
        ("Bitwarden", "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,News,,,0,\"https://news.example.net,https://m.example.net\",sam,pw1,\n,,note,Secret note,text,,0,,,,"),
        ("LastPass", "url,username,password,totp,extra,name,grouping,fav\nhttps://news.example.net,sam,pw1,,,News,,0\nhttp://sn,,,,note,Note,,0"),
        ("Proton Pass", "name,url,email,username,password,note,totp,createTime,modifyTime,vault\nNews,https://news.example.net,sam@example.com,sam,pw1,,,1,1,Personal"),
        ("KeePassXC", "\"Group\",\"Title\",\"Username\",\"Password\",\"URL\",\"Notes\",\"TOTP\"\n\"Root\",\"News\",\"sam\",\"pw1\",\"https://news.example.net\",\"\",\"\""),
    ])
    func commonExportsGiveTheSameLogin(source: String, csv: String) throws {
        let file = try CredentialVaultImport.read(Data(csv.utf8))
        #expect(file.logins.count == 1, "\(source)")
        #expect(file.logins.first?.origin == "https://news.example.net", "\(source)")
        #expect(file.logins.first?.identifier == "sam", "\(source)")
        #expect(file.logins.first?.password == "pw1", "\(source)")
    }

    @Test func quotedFieldsKeepCommasQuotesAndLineBreaks() throws {
        let csv = "\u{FEFF}url,username,password\r\nshop.example.org,sam,\"made-up, \"\"pass\"\"\nline 2\"\r\n"
        let file = try CredentialVaultImport.read(Data(csv.utf8))
        #expect(file.logins.first?.password == "made-up, \"pass\"\nline 2")
        #expect(file.logins.first?.origin == "https://shop.example.org")
    }

    @Test func rowsWithoutASiteUsernameOrPasswordAndRepeatsAreSkipped() throws {
        let csv = "url,username,password\n,sam,pw\nexample.com,,pw\nexample.com,sam,\nexample.com,sam,pw\nEXAMPLE.com,Sam,pw2"
        let file = try CredentialVaultImport.read(Data(csv.utf8))
        #expect(file.logins.count == 1)
        #expect(file.skipped == 4)
    }

    @Test func somethingThatIsntAnExportSaysSo() {
        #expect(throws: CredentialVaultImport.Problem.noColumns) {
            try CredentialVaultImport.read(Data("name,notes\nWi-Fi,router".utf8))
        }
        #expect(throws: CredentialVaultImport.Problem.tooLarge) {
            try CredentialVaultImport.read(Data(count: CredentialVaultImport.maximumBytes + 1))
        }
    }

    @Test func loginsAlreadyInTheVaultArentSentAgainAndTheRestAreSaved() async throws {
        let service = RecordingVault()
        let model = CredentialVaultModel(service: service, agents: [.init(id: "default", name: "Default")],
                                         agentID: "default")
        await model.load()
        let file = try CredentialVaultImport.read(Data("""
        url,username,password,totp
        https://example.com,sam@example.com,pw0,
        https://news.example.net,sam,pw1,not-a-real-key
        """.utf8))
        let pending = file.excluding(model.items)
        #expect(pending.alreadySaved == 1)
        let result = await model.importLogins(pending.logins)
        #expect(result.imported == 1 && result.failed == 0)
        #expect(model.items.contains { $0.label == "news.example.net" })
        #expect(service.calls.filter { $0.method == "vault.add" }.count == 1)
    }
}

@MainActor
private func demoVault(_ service: any CredentialVaultService = DemoCredentialVaultService()) async -> CredentialVaultModel {
    let model = CredentialVaultModel(service: service, agents: [.init(id: "default", name: "Default")], agentID: "default")
    await model.load()
    return model
}

@MainActor
private final class RecordingVault: CredentialVaultService {
    let demo = DemoCredentialVaultService()
    var calls: [(method: String, params: [String: BighelpJSONValue])] = []
    var links: [[String: BighelpJSONValue]] = []
    /// The next `vault.add` of this kind fails, as a computer that stops answering would.
    var failsNextAdd: String?
    var failsRemoves = false
    /// The plugin couldn't be asked whether it copies.
    var cantCheck = false
    /// How the copy route writes back each website.
    var echoesOrigins: (String) -> String = { $0 }

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        calls.append((method, params))
        if method == "vault.add", let kind = failsNextAdd, params["kind"]?.string == kind {
            failsNextAdd = nil
            throw DirectHermesError.notConnected
        }
        if method == "vault.remove", failsRemoves { throw DirectHermesError.notConnected }
        return try await demo.call(method, params: params)
    }

    func canLink() async -> Bool? { cantCheck ? nil : await demo.canLink() }

    func link(_ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        links.append(payload)
        let reply = try await demo.link(payload)
        let copies = (reply["copies"]?.array ?? []).map { copy -> BighelpJSONValue in
            guard var row = copy.object, let origin = row["origin"]?.string else { return copy }
            row["origin"] = .string(echoesOrigins(origin))
            return .object(row)
        }
        return ["copies": .array(copies)]
    }
}

@MainActor
private final class OlderHermes: CredentialVaultService {
    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        throw DirectHermesError.rpcRejected(code: -32601)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}
