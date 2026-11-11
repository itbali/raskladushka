import Foundation

/// Короткие частые слова. Системный спеллчекер слишком снисходителен к словам
/// из 1–3 букв («цу», «pf» считает допустимыми), поэтому для них нужен свой список.
public enum CommonWords {
    public static func contains(_ word: String, language: String) -> Bool {
        guard let set = sets[baseLanguage(language)] else { return false }
        return set.contains(word.lowercased())
    }

    public static func hasList(for language: String) -> Bool {
        sets[baseLanguage(language)] != nil
    }

    static func baseLanguage(_ language: String) -> String {
        String(language.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }

    private static let sets: [String: Set<String>] = [
        "ru": words("""
            я в с к и у о а
            не на по за от до из он мы ты вы же бы ли но да то их ее её ну ни ко со об во ой ах эх ай ок
            ум юг яд ёж уж ух эй ей им ею ем ел ям ад ус ил щи чё та те ту ха хм фу ой ишь ага угу
            ща шт пи гы ин зы ру
            что как это все всё так его для был при уже или еще ещё вот они она оно мне нет где там тут
            сам два три раз год дом без под над про кто чем тем мой моя моё мои наш ваш вас нас нам вам
            ним них ней нее неё лет дня дел ему мир вид час дни вон щас тот эта эти тех том той эту
            чей чья чьё кого куда сюда есть быть надо если даже тоже надо меня тебя себя
            """),
        "en": words("""
            a i
            am an as at be by do go he hi if in is it me my no of ok on or so to up us we vs id pm tv pc
            ui ux os db js ts io ai ip qa pr ci cd hr ad eh oh ah ha yo ex
            kb mb gb dj hd fm uk eu la ny tt ds ls rm cp mv ps sh ssh
            the and for are but not you all any can had her was one our out day get has him his how man
            new now old see two way who boy did its let put say she too use yes yet may why try run set
            got big end far few own off add ago air art ask bad bag bit box buy car cut dog eat fun guy
            hey hot job key kid law lot low map mom dad pay per red sea sit six ten top war win api app
            url css sql git npm cli dev bug fix log tab row col div src img var int str len max min sum
            """),
    ]

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }
}
