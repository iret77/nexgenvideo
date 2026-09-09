"""Semantic review scopes for the frozen 3.1.1 blueprint Verify clauses."""

SCOPES = {
    "wes-anderson": "composition:frame camera:frame lighting:frame color:frame timing:shot",
    "zaz-mel": "character:frame composition:frame camera:shot sound:sequence character:frame",
    "woody-allen": "editing:sequence composition:shot lighting:frame editing:sequence editing:sequence",
    "edgar-wright": "editing:sequence editing:sequence editing:sequence camera:shot timing:sequence",
    "david-fincher": "camera:shot lighting:frame composition:frame color:frame editing:sequence",
    "roger-deakins": "composition:frame composition:frame lighting:frame color:frame timing:shot",
    "stanley-kubrick": "composition:frame composition:frame camera:shot color:frame timing:sequence",
    "steven-spielberg": "composition:frame editing:sequence lighting:frame editing:sequence editing:sequence",
    "denis-villeneuve": "composition:frame composition:frame lighting:frame color:sequence timing:sequence",
    "ridley-scott": "composition:frame lighting:frame composition:frame color:sequence sound:sequence",
    "danny-boyle": "camera:frame color:frame editing:sequence editing:sequence timing:sequence",
    "paul-greengrass": "camera:shot editing:sequence lighting:frame color:frame camera:shot",
    "dardenne-arnold": "camera:shot lighting:frame composition:frame timing:shot sound:sequence",
    "akira-kurosawa": "composition:shot composition:shot camera:frame editing:sequence composition:frame",
    "sergio-leone": "editing:sequence lighting:frame color:frame timing:sequence composition:frame",
    "vince-gilligan": "camera:sequence composition:frame editing:sequence color:sequence lighting:frame",
    "wong-kar-wai": "composition:frame camera:shot lighting:frame color:frame editing:sequence",
    "c-line-sciamma": "composition:frame editing:sequence lighting:frame color:frame sound:sequence",
    "christopher-nolan": "camera:shot lighting:frame color:frame editing:sequence sound:sequence",
    "wachowskis-bill": "color:sequence camera:sequence composition:frame composition:frame editing:sequence",
    "hayao-miyazaki": "composition:shot composition:frame color:frame timing:sequence camera:sequence",
    "quentin-tarantino": "composition:frame camera:shot lighting:frame timing:sequence editing:sequence",
    "martin-scorsese": "editing:sequence camera:shot lighting:frame timing:sequence editing:sequence",
    "alfred-hitchcock": "editing:sequence composition:frame camera:shot timing:sequence lighting:frame",
    "wim-wenders": "composition:shot lighting:frame color:sequence camera:shot timing:sequence",
    "andrei-tarkovsky": "camera:shot composition:frame lighting:frame color:frame camera:shot",
    "yasujir-ozu": "camera:frame camera:shot editing:sequence timing:sequence color:sequence",
    "ingmar-bergman": "composition:frame composition:sequence lighting:frame color:sequence timing:shot",
    "terrence-malick": "lighting:frame camera:shot editing:sequence color:frame sound:sequence",
    "david-lynch": "composition:shot lighting:frame color:frame sound:sequence character:sequence",
    "ugc-found": "camera:sequence composition:frame color:frame editing:sequence camera:shot",
    "emmanuel-lubezki": "lighting:frame camera:frame lighting:frame",
    "hoyte-van": "lighting:frame color:frame lighting:frame",
    "greig-fraser": "lighting:frame composition:frame lighting:frame",
    "vittorio-storaro": "color:sequence lighting:frame lighting:sequence",
    "gordon-willis": "lighting:frame color:frame composition:frame",
    "janusz-kami": "lighting:frame color:frame camera:sequence",
    "christopher-doyle": "color:shot composition:sequence lighting:frame",
    "robby-m": "lighting:frame color:frame composition:frame",
    "sven-nykvist": "lighting:frame composition:frame color:frame",
    "bradford-young": "lighting:frame lighting:frame lighting:frame",
    "claire-mathon": "lighting:frame color:frame composition:frame",
}


def bindings(recipe):
    matches = [value for prefix, value in SCOPES.items()
               if recipe["id"].startswith("director-" + prefix) or recipe["id"].startswith("dop-" + prefix)]
    if len(matches) != 1:
        raise ValueError("Ambiguous or missing review scope: " + recipe["id"])
    clauses = [clause.strip() + "?" for clause in recipe["verifyText"].split("?") if clause.strip()]
    scopes = matches[0].split()
    if len(clauses) != len(scopes):
        raise ValueError("Verify clauses changed: " + recipe["id"])
    result = []
    for index, (clause, binding) in enumerate(zip(clauses, scopes)):
        dimension, scope = binding.split(":")
        result.append({"id": recipe["id"] + ".verify." + str(index),
                       "recipeID": recipe["id"], "sourceClause": clause,
                       "dimension": dimension, "scope": scope,
                       "evidenceKind": "audiovisual" if dimension == "sound" or (
                           recipe["id"].startswith("director-edgar-wright") and index in [0, 2]
                           or recipe["id"].startswith("director-danny-boyle") and index == 2
                           or recipe["id"].startswith("director-martin-scorsese") and index == 0
                           or recipe["id"].startswith("director-quentin-tarantino") and index == 4
                       ) else "image" if scope == "frame" else "video"})
    return result
