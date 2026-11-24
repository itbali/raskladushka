#!/usr/bin/env python3
"""Заполняет карточку «Раскладушки» в App Store Connect и отправляет версию на проверку.

    /usr/bin/python3 Tools/appstore/publish.py --dry-run     # показать, что будет сделано
    /usr/bin/python3 Tools/appstore/publish.py               # заполнить всё, кроме отправки
    /usr/bin/python3 Tools/appstore/publish.py --submit      # заполнить и отправить на проверку
    /usr/bin/python3 Tools/appstore/publish.py --withdraw    # снять с проверки отклонённую или ждущую отправку
    … --replace-screenshots                                  # заменить уже загруженные скриншоты новыми

Запускать системным Python: у отдельно установленного может не быть корневых сертификатов.

Нужно заранее: запись приложения в App Store Connect (API её создавать не умеет), загруженная сборка
(Tools/release.sh --upload) и опубликованные страницы поддержки и политики (папка Site/).
Через API не задаётся раздел «Конфиденциальность приложения» — там вручную выбрать «Данные не собираются».
Тексты берутся из AppStore/metadata.md, заметки для проверки — из AppStore/review-notes.md.
"""
import hashlib, os, re, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import APIError, call, get, get_all  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUNDLE = "com.alexey.duzhev.raskladushka"
SUPPORT = "https://itbali.github.io/raskladushka-site/"
PRIVACY = "https://itbali.github.io/raskladushka-site/privacy.html"
COPYRIGHT = "2026 Aleksei Diuzhev"
PLATFORM = "MAC_OS"
SHOT_TYPE = "APP_DESKTOP"
DRY = "--dry-run" in sys.argv
SUBMIT = "--submit" in sys.argv
REPLACE_SHOTS = "--replace-screenshots" in sys.argv
WITHDRAW = "--withdraw" in sys.argv
LABELS = {
    "ru": {"name": "Название", "subtitle": "Подзаголовок", "promo": "Рекламный текст", "keywords": "Ключевые слова",
           "description": "Описание"},
    "en-US": {"name": "Name", "subtitle": "Subtitle", "promo": "Promotional text", "keywords": "Keywords",
              "description": "Description"},
}
LIMITS = {"name": 30, "subtitle": 30, "promo": 170, "keywords": 100, "description": 4000}
AGE = {
    "advertising": False, "alcoholTobaccoOrDrugUseOrReferences": "NONE", "contests": "NONE", "gambling": False,
    "gamblingSimulated": "NONE", "gunsOrOtherWeapons": "NONE", "healthOrWellnessTopics": False, "lootBox": False,
    "medicalOrTreatmentInformation": "NONE", "messagingAndChat": False, "parentalControls": False,
    "profanityOrCrudeHumor": "NONE", "ageAssurance": False, "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE", "horrorOrFearThemes": "NONE", "matureOrSuggestiveThemes": "NONE",
    "unrestrictedWebAccess": False, "userGeneratedContent": False, "violenceCartoonOrFantasy": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE", "violenceRealistic": "NONE", "socialMedia": False,
}


def say(*a):
    print(("[dry] " if DRY else "") + " ".join(str(x) for x in a))


def unwrap(text):
    """В metadata.md строки перенесены для чтения; магазину нужен один абзац на строку."""
    out = []
    for line in text.strip().splitlines():
        line = line.rstrip()
        fresh = not out or not out[-1] or not line or line.startswith("• ") or len(out[-1]) < 20
        if fresh:
            out.append(line.strip())
        else:
            out[-1] += " " + line.strip()
    return "\n".join(out)


def parse():
    md = open(f"{ROOT}/AppStore/metadata.md", encoding="utf-8").read()
    ru, en, tail = md.index("## Русский"), md.index("## English"), md.index("## Скриншоты")
    out = {}
    for loc, sec in (("ru", md[ru:en]), ("en-US", md[en:tail])):
        fields = {}
        for key, label in LABELS[loc].items():
            m = re.search(r"\*\*" + re.escape(label) + r"[^*]*:\*\*(.*?)(?=\n\*\*|\Z)", sec, re.S)
            value = unwrap(m.group(1)) if key in ("description", "promo") else m.group(1).strip().splitlines()[0].strip()
            assert 0 < len(value) <= LIMITS[key], f"{loc} {key}: {len(value)} > {LIMITS[key]}"
            fields[key] = value
        out[loc] = fields
    return out


def upsert_localizations(kind, parent_path, rel, parent_type, parent_id, wanted):
    have = {l["attributes"]["locale"]: l for l in get_all(parent_path)}
    for loc, attrs in wanted.items():
        if loc in have:
            current = have[loc]["attributes"]
            change = {k: v for k, v in attrs.items() if current.get(k) != v}
            if change:
                say(kind, loc, "update", ", ".join(change))
                if not DRY:
                    call("PATCH", f"/v1/{kind}/{have[loc]['id']}",
                         {"data": {"type": kind, "id": have[loc]["id"], "attributes": change}})
        else:
            say(kind, loc, "create", ", ".join(attrs))
            if not DRY:
                call("POST", f"/v1/{kind}", {"data": {"type": kind, "attributes": {"locale": loc, **attrs},
                                                      "relationships": {rel: {"data": {"type": parent_type, "id": parent_id}}}}})


def upload_screenshots(loc_id, lang):
    folder = f"{ROOT}/AppStore/screenshots"
    files = sorted(f for f in os.listdir(folder) if f.endswith(f"-{lang}.png"))
    sets = get_all(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")
    shot_set = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == SHOT_TYPE), None)
    there = get_all(f"/v1/appScreenshotSets/{shot_set['id']}/appScreenshots") if shot_set else []
    if there and REPLACE_SHOTS:
        say("screenshots", lang, "deleting", len(there))
        if not DRY:
            for shot in there:
                call("DELETE", f"/v1/appScreenshots/{shot['id']}")
    elif there:
        say("screenshots", lang, "already there:", len(there))
        return
    say("screenshots", lang, len(files), "x", SHOT_TYPE)
    if DRY:
        return
    if not shot_set:
        shot_set = call("POST", "/v1/appScreenshotSets", {"data": {
            "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": SHOT_TYPE},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})["data"]
    for f in files:
        blob = open(f"{folder}/{f}", "rb").read()
        res = call("POST", "/v1/appScreenshots", {"data": {
            "type": "appScreenshots", "attributes": {"fileName": f, "fileSize": len(blob)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": shot_set["id"]}}}}})["data"]
        for op in res["attributes"]["uploadOperations"]:
            req = urllib.request.Request(op["url"], data=blob[op["offset"]:op["offset"] + op["length"]], method=op["method"],
                                         headers={h["name"]: h["value"] for h in op["requestHeaders"]})
            urllib.request.urlopen(req).read()
        call("PATCH", f"/v1/appScreenshots/{res['id']}", {"data": {
            "type": "appScreenshots", "id": res["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
        say("  uploaded", f)


def review_contact(app_id):
    """Контакт для проверки берётся из другого приложения аккаунта."""
    for other in get_all("/v1/apps?limit=50"):
        if other["id"] == app_id:
            continue
        for v in get_all(f"/v1/apps/{other['id']}/appStoreVersions?limit=3"):
            d = get(f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail").get("data")
            if d and d["attributes"].get("contactPhone"):
                return {k: d["attributes"][k] for k in ("contactFirstName", "contactLastName", "contactEmail", "contactPhone")}
    sys.exit("В других приложениях аккаунта нет контакта для проверки: заполните его вручную.")


def main():
    meta = parse()
    found = get(f"/v1/apps?filter%5BbundleId%5D={BUNDLE}")["data"]
    if not found:
        sys.exit(f"В App Store Connect нет приложения с идентификатором {BUNDLE}: создайте запись (Приложения → «+»).")
    app = found[0]
    app_id = app["id"]

    if WITHDRAW:
        # Снять с проверки отправку, по которой Apple ждёт ответа (или которая ещё в очереди).
        # После этого версия снова редактируется, и её можно отправить заново обычным --submit.
        pending = [s for s in get_all(f"/v1/reviewSubmissions?filter%5Bapp%5D={app_id}&filter%5Bplatform%5D={PLATFORM}")
                   if s["attributes"]["state"] in ("UNRESOLVED_ISSUES", "WAITING_FOR_REVIEW", "READY_FOR_REVIEW")]
        if not pending:
            say("нет отправок, которые можно снять")
        for sub in pending:
            say("withdraw submission", sub["id"], sub["attributes"]["state"])
            if not DRY:
                done = call("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {
                    "type": "reviewSubmissions", "id": sub["id"], "attributes": {"canceled": True}}})["data"]
                say("  now:", done["attributes"]["state"])
        return
    version_str = re.search(r'MARKETING_VERSION: "([^"]+)"', open(f"{ROOT}/project.yml").read()).group(1)
    build_str = re.search(r'CURRENT_PROJECT_VERSION: "([^"]+)"', open(f"{ROOT}/project.yml").read()).group(1)

    # Страницы должны открываться — иначе Apple вернёт карточку.
    for url in (SUPPORT, PRIVACY):
        try:
            urllib.request.urlopen(url, timeout=20).read(100)
        except Exception as e:  # noqa: BLE001
            msg = f"не открывается {url}: {e}"
            if DRY or ("--skip-url-check" in sys.argv and not SUBMIT):
                say("ВНИМАНИЕ:", msg)
            else:
                sys.exit(msg)

    if app["attributes"].get("contentRightsDeclaration") != "DOES_NOT_USE_THIRD_PARTY_CONTENT":
        say("content rights: no third-party content")
        if not DRY:
            call("PATCH", f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id, "attributes": {
                "contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})

    info = next(i for i in get_all(f"/v1/apps/{app_id}/appInfos")
                if i["attributes"].get("appStoreState", i["attributes"].get("state")) != "READY_FOR_SALE")
    upsert_localizations("appInfoLocalizations", f"/v1/appInfos/{info['id']}/appInfoLocalizations", "appInfo",
                         "appInfos", info["id"],
                         {loc: {"name": m["name"], "subtitle": m["subtitle"], "privacyPolicyUrl": PRIVACY}
                          for loc, m in meta.items()})
    say("categories: Utilities, Productivity")
    if not DRY:
        call("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
            "primaryCategory": {"data": {"type": "appCategories", "id": "UTILITIES"}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": "PRODUCTIVITY"}}}}})

    age = get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration")["data"]
    change = {k: v for k, v in AGE.items() if age["attributes"].get(k) != v}
    if change:
        say("age rating:", len(change), "answers")
        if not DRY:
            call("PATCH", f"/v1/ageRatingDeclarations/{age['id']}",
                 {"data": {"type": "ageRatingDeclarations", "id": age["id"], "attributes": change}})

    versions = get_all(f"/v1/apps/{app_id}/appStoreVersions?filter%5Bplatform%5D={PLATFORM}")
    editable = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY")
    version = next((v for v in versions if v["attributes"]["appStoreState"] in editable), None)
    if not version:
        sys.exit("Нет версии macOS в состоянии «Подготовка к отправке»: " +
                 ", ".join(v["attributes"]["appStoreState"] for v in versions))
    # Публикация сразу после одобрения.
    attrs = {"versionString": version_str, "copyright": COPYRIGHT, "releaseType": "AFTER_APPROVAL"}
    change = {k: v for k, v in attrs.items() if version["attributes"].get(k) != v}
    if change:
        say("version", change)
        if not DRY:
            call("PATCH", f"/v1/appStoreVersions/{version['id']}",
                 {"data": {"type": "appStoreVersions", "id": version["id"], "attributes": change}})
    upsert_localizations("appStoreVersionLocalizations",
                         f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
                         "appStoreVersion", "appStoreVersions", version["id"],
                         {loc: {"description": m["description"], "keywords": m["keywords"],
                                "promotionalText": m["promo"], "supportUrl": SUPPORT} for loc, m in meta.items()})
    for loc_obj in get_all(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations"):
        lang = {"ru": "ru", "en-US": "en"}.get(loc_obj["attributes"]["locale"])
        if lang:
            upload_screenshots(loc_obj["id"], lang)

    notes = open(f"{ROOT}/AppStore/review-notes.md", encoding="utf-8").read().split("\n", 1)[1].strip()
    assert len(notes) <= 4000, len(notes)
    detail = get(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
    if not detail:
        contact = review_contact(app_id)
        say("review contact:", contact["contactFirstName"], contact["contactLastName"])
        if not DRY:
            call("POST", "/v1/appStoreReviewDetails", {"data": {
                "type": "appStoreReviewDetails", "attributes": {**contact, "demoAccountRequired": False, "notes": notes},
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
    elif detail["attributes"].get("notes") != notes:
        say("review notes:", len(notes), "characters")
        if not DRY:
            call("PATCH", f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {
                "type": "appStoreReviewDetails", "id": detail["id"], "attributes": {"notes": notes}}})

    try:
        priced = bool(get(f"/v1/appPriceSchedules/{app_id}/manualPrices").get("data"))
    except APIError as e:
        if e.code != 404:
            raise
        priced = False
    if not priced:
        points = get_all(f"/v1/apps/{app_id}/appPricePoints?filter%5Bterritory%5D=USA&limit=200")
        free = next(p for p in points if float(p["attributes"]["customerPrice"]) == 0)
        say("price: free")
        if not DRY:
            call("POST", "/v1/appPriceSchedules", {
                "data": {"type": "appPriceSchedules", "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}},
                    "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                    "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
                "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                              "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})

    try:
        get(f"/v1/apps/{app_id}/appAvailabilityV2")
        available = True
    except APIError as e:
        if e.code != 404:
            raise
        available = False
    if not available:
        territories = [t["id"] for t in get_all("/v1/territories?limit=200")]
        say("availability:", len(territories), "territories and new ones")
        if not DRY:
            call("POST", "/v2/appAvailabilities", {
                "data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
                         "relationships": {
                             "app": {"data": {"type": "apps", "id": app_id}},
                             "territoryAvailabilities": {"data": [
                                 {"type": "territoryAvailabilities", "id": f"${{{t}}}"} for t in territories]}}},
                "included": [{"type": "territoryAvailabilities", "id": f"${{{t}}}",
                              "attributes": {"available": True, "releaseDate": None, "preOrderEnabled": False},
                              "relationships": {"territory": {"data": {"type": "territories", "id": t}}}}
                             for t in territories]})

    builds = [b for b in get_all(f"/v1/builds?filter%5Bapp%5D={app_id}&filter%5Bversion%5D={build_str}"
                                 f"&filter%5BpreReleaseVersion.version%5D={version_str}&limit=10")]
    build = next((b for b in builds if b["attributes"]["processingState"] == "VALID"), None)
    if build:
        say("build", version_str, f"({build_str})")
        if not DRY:
            call("PATCH", f"/v1/appStoreVersions/{version['id']}/relationships/build",
                 {"data": {"type": "builds", "id": build["id"]}})
    else:
        say("ВНИМАНИЕ: сборка", version_str, f"({build_str})", "не найдена или ещё обрабатывается:",
            [b["attributes"]["processingState"] for b in builds])

    if SUBMIT:
        if not build:
            sys.exit("Без обработанной сборки отправить на проверку нельзя.")
        say("submit for review")
        if not DRY:
            open_subs = [s for s in get_all(f"/v1/reviewSubmissions?filter%5Bapp%5D={app_id}&filter%5Bplatform%5D={PLATFORM}")
                         if s["attributes"]["state"] in ("READY_FOR_REVIEW",)]
            sub = open_subs[0] if open_subs else call("POST", "/v1/reviewSubmissions", {"data": {
                "type": "reviewSubmissions", "attributes": {"platform": PLATFORM},
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
            if not get_all(f"/v1/reviewSubmissions/{sub['id']}/items"):
                call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
            done = call("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {
                "type": "reviewSubmissions", "id": sub["id"], "attributes": {"submitted": True}}})["data"]
            say("review submission:", done["attributes"]["state"])
    say("done")


if __name__ == "__main__":
    main()
