//! The agent proposes rules; the system verifies each; you approve, change or reject it; approved rules are enforced.
//! A proposal is a new rule written as a sentence, a rule of the catalog linked somewhere, or a rule switched off
//! somewhere with a reason. Verification says whether it is written right, whether it repeats a rule or another
//! proposal, whether it contradicts a linked rule, and what it would break if approved.

use serde::{Deserialize, Serialize};

use super::custom::{CustomRule, Provenance, Sentence};
use super::{ALL, Catalog, Enforce, Finding, Link, RuleSet, Scope, Tally, admit, check_with, describe};
use crate::{Schema, Target};

/// What the agent proposes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Proposed {
    /// A new rule, written as a sentence.
    New {
        sentence: Sentence,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        targets: Vec<Target>,
    },
    /// A rule of the catalog, linked where the proposal says.
    Link { rule: String },
    /// A rule, or every rule (`*`), switched off where the proposal says.
    Off { rule: String, reason: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Proposed,
    Approved,
    Rejected,
}

/// One proposal, as kept.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Proposal {
    /// Its number in the schema, from 1.
    pub id: u64,
    /// Who proposed it: `agent`.
    pub by: String,
    pub what: Proposed,
    pub at: Scope,
    /// Hard (enforced) or soft (highlighted only); you can change it before approving.
    pub enforce: Enforce,
    /// The proposer's evidence: why the rule fits.
    pub why: String,
    pub status: Status,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decided_by: Option<String>,
    /// For an approved new rule, the id it was given.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    /// Verified: it can be approved.
    Ready,
    /// It contradicts a linked rule: approve it only with that rule switched off, or reject it.
    Conflict,
    /// It repeats a rule or another proposal.
    Duplicate,
    /// It cannot be taken: not written right, or a level that is not there.
    Invalid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Mark {
    Ok,
    New,
    Reuse,
    Warn,
    Bad,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Note {
    pub mark: Mark,
    pub text: String,
}

/// The system's word on a proposal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Verdict {
    pub state: State,
    /// The proposal in words, as it would run.
    pub title: String,
    pub notes: Vec<Note>,
    /// What it would look at and break if approved.
    pub tally: Tally,
    /// The first things it would break.
    pub breaks: Vec<Finding>,
    /// The linked rules it contradicts, for the choice a conflict asks for.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub conflicts: Vec<String>,
}

const PREVIEW: &str = "proposal";

fn note(mark: Mark, text: impl Into<String>) -> Note {
    Note { mark, text: text.into() }
}

/// The rule a new proposal would add, for the preview and for approval.
#[must_use]
pub fn draft(p: &Proposal, id: &str, approved_by: &str, schema: &str, target: Target) -> Option<CustomRule> {
    let Proposed::New { sentence, targets } = &p.what else { return None };
    Some(CustomRule {
        id: id.to_string(),
        sentence: sentence.clone(),
        hard: p.enforce == Enforce::Hard,
        targets: sentence.targets(targets, target),
        why: p.why.clone(),
        provenance: Provenance {
            proposed_by: p.by.clone(),
            approved_by: approved_by.to_string(),
            proposal: format!("{schema}#{}", p.id),
        },
    })
}

/// The link a proposal adds when it is approved, the rule named `rule` for a new one.
#[must_use]
pub fn link_of(p: &Proposal, rule: &str) -> Link {
    match &p.what {
        Proposed::New { .. } | Proposed::Link { .. } => Link {
            rule: rule.to_string(),
            at: p.at.clone(),
            off: false,
            locked: false,
            reason: None,
            enforce: Some(p.enforce),
        },
        Proposed::Off { reason, .. } => Link {
            rule: rule.to_string(),
            at: p.at.clone(),
            off: true,
            locked: false,
            reason: Some(reason.clone()),
            enforce: None,
        },
    }
}

/// Everything the verification reads.
pub struct Context<'a> {
    pub cat: &'a Catalog,
    pub custom: &'a [CustomRule],
    pub schema: &'a Schema,
    pub global: &'a [Link],
    pub set: &'a RuleSet,
    /// Every proposal of the schema, this one among them.
    pub proposals: &'a [Proposal],
}

/// Verifies proposal `p`.
#[must_use]
pub fn verify(cx: &Context<'_>, p: &Proposal) -> Verdict {
    let mut notes = Vec::new();
    let mut state = State::Ready;
    let mut conflicts = Vec::new();
    if p.at == Scope::Global {
        let notes = vec![note(Mark::Bad, "Rules for every schema are yours to link: propose them for this schema")];
        return Verdict {
            state: State::Invalid,
            title: title(cx, p),
            notes,
            tally: Tally::default(),
            breaks: Vec::new(),
            conflicts,
        };
    }
    let families = super::families(cx.schema);
    if !super::exists(cx.schema, cx.set, &families, &p.at) {
        notes.push(note(Mark::Bad, format!("{} is not in this schema", describe(&p.at))));
        return Verdict {
            state: State::Invalid,
            title: title(cx, p),
            notes,
            tally: Tally::default(),
            breaks: Vec::new(),
            conflicts,
        };
    }
    let (cat, rule) = match &p.what {
        Proposed::New { sentence, targets } => {
            if let Err(e) = sentence.valid(cx.schema.target) {
                notes.push(note(Mark::Bad, format!("Not written right: {e}")));
                return Verdict {
                    state: State::Invalid,
                    title: title(cx, p),
                    notes,
                    tally: Tally::default(),
                    breaks: Vec::new(),
                    conflicts,
                };
            }
            notes.push(note(Mark::Ok, "Written in the rule grammar: it runs as data, not code"));
            let target = cx.schema.target;
            let holds_on = sentence.targets(targets, target);
            if let Some(same) = cx.custom.iter().find(|c| &c.sentence == sentence && c.targets == holds_on) {
                state = State::Duplicate;
                notes.push(note(Mark::Reuse, format!("Already a rule: `{}` says the same. Link it instead", same.id)));
            } else if let Some(other) = cx.proposals.iter().find(|o| {
                o.id < p.id
                    && o.status == Status::Proposed
                    && matches!(&o.what, Proposed::New { sentence: s, targets: t }
                        if s == sentence && s.targets(t, target) == holds_on)
            }) {
                state = State::Duplicate;
                notes.push(note(Mark::Reuse, format!("Proposal #{} says the same", other.id)));
            } else {
                notes.push(note(Mark::New, "A new rule: no rule of the catalog says it"));
            }
            let draft = draft(p, PREVIEW, "", "", cx.schema.target).expect("a new rule");
            (cx.cat.with(std::slice::from_ref(&draft)), PREVIEW.to_string())
        }
        Proposed::Link { rule } | Proposed::Off { rule, .. } => {
            let link = link_of(p, rule);
            let there = cx.set.links.iter().chain(cx.global).find(|l| l.rule == link.rule && l.at == link.at);
            match there.map_or_else(|| admit(cx.cat, cx.schema, cx.global, cx.set, &link), |_| Ok(())) {
                Ok(()) if there.is_some() => {
                    state = State::Duplicate;
                    let how = if there.is_some_and(|l| l.off) { "switched off" } else { "linked" };
                    notes.push(note(Mark::Reuse, format!("Already there: `{rule}` is {how} at {}", describe(&p.at))));
                }
                Ok(()) => {
                    let what = if rule == ALL {
                        "every rule".to_string()
                    } else {
                        format!("`{}`", cx.cat.rule(rule).map_or(rule.as_str(), |r| r.title.as_str()))
                    };
                    let text = match &p.what {
                        Proposed::Off { reason, .. } => format!("Switches {what} off at {}: {reason}", describe(&p.at)),
                        _ => format!("Reuses {what} from the catalog"),
                    };
                    notes.push(note(
                        if matches!(p.what, Proposed::Off { .. }) { Mark::Warn } else { Mark::Reuse },
                        text,
                    ));
                }
                Err(e) => {
                    notes.push(note(Mark::Bad, e));
                    return Verdict {
                        state: State::Invalid,
                        title: title(cx, p),
                        notes,
                        tally: Tally::default(),
                        breaks: Vec::new(),
                        conflicts,
                    };
                }
            }
            (cx.cat.with(&[]), rule.clone())
        }
    };
    // What it contradicts: columns that keep a new type rule only by breaking a type rule already linked.
    if let Proposed::New { sentence, .. } = &p.what
        && matches!(sentence, Sentence::Columns { .. })
    {
        let now = check_with(cx.cat, cx.schema, cx.global, cx.set);
        let mut against: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
        for f in now.findings.iter().filter(|f| f.column.is_some()) {
            let Some(r) = cx.cat.rule(&f.rule).filter(|r| matches!(r.topic, "types" | "compatibility")) else {
                continue;
            };
            let t = cx.schema.tables.iter().find(|t| t.id == f.table);
            let c = t.and_then(|t| t.columns.iter().find(|c| Some(&c.id) == f.column.as_ref()));
            if c.is_some_and(|c| sentence.keeps_column(&c.name, &c.data_type) == Some(true)) {
                *against.entry(r.id.clone()).or_default() += 1;
            }
        }
        for (id, n) in &against {
            let r = cx.cat.rule(id).expect("a rule");
            notes.push(note(
                Mark::Bad,
                format!("Contradicts \"{}\" ({id}): {n} columns keep this rule only by breaking it", r.title),
            ));
            conflicts.push(id.clone());
        }
        if !against.is_empty() && state == State::Ready {
            state = State::Conflict;
        } else if against.is_empty() {
            notes.push(note(Mark::Ok, "Contradicts no linked rule"));
        }
    }
    // What it would break if approved.
    let mut set = cx.set.clone();
    set.links.retain(|l| !(l.rule == rule && l.at == p.at));
    set.links.push(link_of(p, &rule));
    let after = check_with(&cat, cx.schema, cx.global, &set);
    let (tally, breaks) = match &p.what {
        Proposed::Off { .. } => {
            let before = check_with(&cat, cx.schema, cx.global, cx.set);
            let gone = before.findings.len().saturating_sub(after.findings.len());
            notes.push(note(
                Mark::Ok,
                format!("If approved: {gone} {} away", if gone == 1 { "finding goes" } else { "findings go" }),
            ));
            (Tally::default(), Vec::new())
        }
        _ => {
            let checks = cat.checks(&rule);
            let tally = after.tallies.get(&rule).cloned().unwrap_or_default();
            let breaks: Vec<Finding> =
                after.findings.iter().filter(|f| checks.contains(&f.rule.as_str())).take(20).cloned().collect();
            let n = tally.breaks;
            notes.push(note(
                if n == 0 { Mark::Ok } else { Mark::Warn },
                if n == 0 {
                    format!("If approved: all {} it looks at pass", tally.checked)
                } else {
                    format!("If approved: {n} of {} it looks at break it", tally.checked)
                },
            ));
            (tally, breaks)
        }
    };
    Verdict { state, title: title(cx, p), notes, tally, breaks, conflicts }
}

/// The proposal in words: a new rule's sentence, or the rule it links or switches off.
#[must_use]
pub fn title(cx: &Context<'_>, p: &Proposal) -> String {
    match &p.what {
        Proposed::New { sentence, .. } => sentence.words(),
        Proposed::Link { rule } => cx.cat.rule(rule).map_or_else(|| rule.clone(), |r| r.title.clone()),
        Proposed::Off { rule, .. } if rule == ALL => "No rules here".to_string(),
        Proposed::Off { rule, .. } => {
            format!("Switch off: {}", cx.cat.rule(rule).map_or(rule.as_str(), |r| r.title.as_str()))
        }
    }
}
