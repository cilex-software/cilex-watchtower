// The Watch — display names for ranks and badge families. The mythology is
// entirely client-side (backend "has no opinion about ravens"). qsTranslate
// with an explicit context so lupdate picks these up from a .js library.
.pragma library

function rankName(key) {
    switch (key) {
    case "copper":   return qsTranslate("TheWatch", "Copper");
    case "iron":     return qsTranslate("TheWatch", "Iron");
    case "silver":   return qsTranslate("TheWatch", "Silver");
    case "amber":    return qsTranslate("TheWatch", "Amber");
    case "raven":    return qsTranslate("TheWatch", "Raven");
    case "sentinel": return qsTranslate("TheWatch", "Sentinel");
    default:         return key;
    }
}

function familyName(key) {
    switch (key) {
    case "hours":      return qsTranslate("TheWatch", "Hours on Watch");
    case "nightwatch": return qsTranslate("TheWatch", "Night Watch");
    case "hollow":     return qsTranslate("TheWatch", "Hollow Hours");
    case "sunrise":    return qsTranslate("TheWatch", "Sunrise Watch");
    case "fullmoon":   return qsTranslate("TheWatch", "Full Moon");
    case "yearkeeper": return qsTranslate("TheWatch", "Yearkeeper");
    case "steadfast":  return qsTranslate("TheWatch", "Steadfast");
    case "cleanwatch": return qsTranslate("TheWatch", "Clean Watch");
    case "wayfarer":   return qsTranslate("TheWatch", "Wayfarer");
    case "vigilance":  return qsTranslate("TheWatch", "Vigilance");
    case "weather":    return qsTranslate("TheWatch", "Weather Watch");
    default:           return key;
    }
}

function tierName(key) {
    switch (key) {
    case "copper": return qsTranslate("TheWatch", "Copper");
    case "iron":   return qsTranslate("TheWatch", "Iron");
    case "silver": return qsTranslate("TheWatch", "Silver");
    case "amber":  return qsTranslate("TheWatch", "Amber");
    default:       return key;
    }
}
