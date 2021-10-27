module Explorer.I18n.DE where

import Explorer.I18n.Types (Translation)

translation :: Translation
translation =
    { common:
        { cBack: "Zurück"
        , cBCC: "BCC"
        , cBCshort: "BC"
        , cBCong: "Bitcoin"
        , cApi: "Api"
        , cTransaction: "Transaktion"
        , cTransactions: "Transaktionen"
        , cTransactionFeed: "Transaktionen Feed"
        , cAddress: "Adresse"
        , cAddresses: "Adressen"
        , cCalculator: "Rechner"
        , cNetwork: "Netzwerk"
        , cVersion: "Version"
        , cSummary: "Zusammenfassung"
        , cBlock: "Slot"
        , cGenesis: "Genesis Block"
        , cHash: "Hash"
        , cHashes: "Hashes"
        , cEpoch: "Epoche"
        , cEpochs: "Epochen"
        , cSlot: "Slot"
        , cSlots: "Slots"
        , cAge: "Seit"
        , cTotalSent: "Insgesamt gesendet"
        , cBlockLead: "Weitergegeben durch"
        , cSize: "Größe (bytes)"
        , cExpand: "Aufklappen"
        , cCollapse: "Zuklappen"
        , cNoData: "Keine Daten"
        , cTitle: "Bcc Blockchain Explorer"
        , cCopyright: "Bcc Blockchain Explorer @2017"
        , cUnknown: "Unbekannt"
        , cTotalOutput: "Gesamtausgabe"
        , cOf: "von"
        , cNotAvailable: "nicht verfügbar"
        , cLoading: "Lade..."
        , cBack2Dashboard: "Zurück zum Dashboard"
        , cYes: "ja"
        , cNo: "nein"
        , cDays: "Tage"
        , cHours: "Stunden"
        , cMinutes: "Minuten"
        , cSeconds: "Sekunden"
        , cDateFormat: "DD.MM.YYYY HH:mm:ss"
        , cDecimalSeparator: ","
        , cGroupSeparator: "."
        }
    , navigation:
        { navHome: "Home"
        , navBlockchain: "Blockchain"
        , navMarket: "Markt"
        , navCharts: "Charts"
        , navTools: "Tools"
        }
    , hero:
        { hrSubtitle: "Suche Adressen, Transaktionen, Epochen und Slots im Bcc Netzwerk"
        , hrSearch: "Suche Adressen, Transaktionen, Slots und Epochen"
        , hrTime: "Zeit"
        }
    , dashboard:
        { dbTitle: "Dashboard"
        , dbLastBlocks: "Aktuelle Slots"
        , dbLastBlocksDescription: "Am {0} wurden {1} Transakationen generiert."
        , dbPriceAverage: "Price (Durchschnitt)"
        , dbPriceForOne: "{0} für 1 {1}"
        , dbPriceSince: "{0} seid gestern."
        , dbTotalSupply: "Gesamtumsatz"
        , dbTotalAmountOf: "Anzahl von {0} im System."
        , dbTotalAmountOfTransactions: "Gesamtanzahl von erfassten Transaktionen im System seit Beginn an."
        , dbExploreBlocks: "Blöcke erkunden"
        , dbExploreTransactions: "Transaktionen erkunden"
        , dbBlockchainOffer: "Was bieten wir mit unserem Block Explorer"
        , dbBlockSearch: "Slotsuche"
        , dbBlockSearchDescription: "Slot ist eine Box, in der Transaktionen gespeichert werden."
        , dbAddressSearch: "Adresssuche"
        , dbAddressSearchDescription: "Adresssuche"
        , dbTransactionSearch: "Transaktionssuche"
        , dbTransactionSearchDescription: "Transaktion ist der Transfer von Münzem vom Benutzer 'A' zum Benutzer 'B'."
        , dbApiDescription: "Unsere robuste API ist in unterschiedlichen Sprachen und SDKs verfügbar."
        , dbGetAddress: "Adresse abfragen"
        , dbResponse: "Antwort"
        , dbCurl: "Curl"
        , dbNode: "Node"
        , dbJQuery: "jQuery"
        , dbGetApiKey: "API key anfordern"
        , dbMoreExamples: "Mehr Beispiele"
        , dbAboutBlockchain: "Über Blockchain"
        , dbAboutBlockchainDescription: "Mit der Blockchain API ist es einfach Anwendungen für Kryptowährung zu entwickeln. Wir sind bestrebt eine Plattform anzubieten, mit der Entwickler schnell skalierbare und sichere Services umsetzen können.<br/><br/>Diese API ist kostenlos and unbeschränkt nutzbar während der Beta Phase. Wir haben gerade gestartet und werden nach und nach mehr Endpunkte und Funktionen in den kommenden Wochen anbieten. Wir wollen die API anbieten, die Sie wirklich benötigen. Darum senden Sie uns bitte Wünsche und Verbesserungsvorschläge oder sagen Sie einfach nur 'Hallo'."
        }
    , address:
        { addScan: "Scannen Sie hier den QR Code, um die Adresse in die Zwischenablage zu kopieren."
        , addQrCode: "QR-Code"
        , addFinalBalance: "Aktueller Kontostand"
        , addNotFound: "Adresse existiert nicht."
        }
    , tx:
        { txTime: "Eingangszeit"
        , txIncluded: "Bestand in"
        , txRelayed: "Weitergabe per IP"
        , txEmpty: "Keine Transaktionen"
        , txFees: "Transaktionsgebühr"
        , txNotFound: "Transaktion existiert nicht."
        }
    , block:
        { blFees: "Gebühren"
        , blEstVolume: "Geschätztes Volumen"
        , blPrevBlock: "Vorheriger Slot"
        , blNextBlock: "Nächster Slot"
        , blRoot: "Oberer Slot"
        , blEpochSlotNotFound: "Fehler: Epoche / Slot konnte nicht gefunden werden."
        , blSlotNotFound: "Slot existiert nicht."
        , blSlotEmpty: "Leerer Slot"
        }
    , genesisBlock:
        { gblNotFound: "Genesis Block existiert nicht."
        , gblNumberRedeemedAddresses: "Bereits eingelöste Adressen"
        , gblNumberNotRedeemedAddresses: "Noch einzulösende Addressen"
        , gblNumberAddressesToRedeem: "Gesamtzahl einzulösender Addressen"
        , gblRedeemedAmountTotal: "Bereits eingelöster Betrag"
        , gblNonRedeemedAmountTotal: "Noch einzulösender Betrag"
        , gblFilterAll: "Alle"
        , gblFilterRedeemed: "Bereits eingelöst"
        , gblFilterNonRedeemed: "Noch einzulösen"
        , gblAddressesNotFound: "Adressen existieren nicht."
        , gblAddressesError: "Error beim Laden der Addressen"
        , gblAddressRedeemAmount: "Einzulösender Wert"
        , gblAddressIsRedeemed: "eingelöst"
        }
    , footer:
        { fooIohkSupportP: "TBCO unterstütztes Projekt"
        , fooGithub: "Github"
        , fooEmail: "Email"
        , fooTwitter: "Twitter"
        , fooKlarityPlatform: "Bezalel Plattform"
        , fooWhyBcc: "Warum Bcc"
        , fooBccRoadmap: "Bcc Roadmap"
        , fooBccSource: "Bcc Source"
        , fooBccFoundation: "Bcc Foundation"
        , fooBccFoundationYoutube: "Bcc Foundation YouTube"
        , fooBccFoundationTwitter: "Bcc Foundation Twitter"
        , fooBccHub: "Bcc Hub"
        , fooBccChat: "Bcc Chat"
        , fooBccForum: "Bcc Forum"
        , fooBccReddit: "Bcc Reddit"
        , fooBccCommunity: "Bcc Community"
        , fooBccDocumentation: "Bcc Dokumentation"
        , fooBccTestnet: "Bcc Testnet"
        , fooBccOpenSource: "Bcc ist ein Open Source Projekt."
        , fooTBCO: "TBCO"
        , fooTBCOBlog: "TBCO Blog"
        , fooTBCOYoutube: "TBCO YouTube"
        , fooDisclaimerPt1: "Bcc ist NUR eine Softwareplattform und führt keine unabhängige Sorgfalt oder inhaltliche Überprüfung von Blockketten, digitalen Währungen, Kryptowährungen oder zugehörigen Technologien durch. Ihre Nutzung dieser Website und Software erfolgt auf eigene Gefahr, und diese Website wird auf einer \"as is\"-Basis und nur als Referenz zur Verfügung gestellt."
        , fooDisclaimerPt2: ""
        , fooProject: "Das Projekt"
        , fooProtocol: "Das Protokoll"
        , fooFoundation: "Die Foundation"
        , fooLearnMore: "Mehr erfahren"
      }
    , notfound:
        { nfTitle: "404"
        , nfDescription: "Seite nicht gefunden"
        }
    }
