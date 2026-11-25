//! For every class of defect the task file lists, one test: a copy of the repository's files, one defect planted in
//! it, and the finding the check must give. The tests named in_docker load the copy on PostgreSQL 18 in Docker.

use schema_forge_specs::{Finding, check, load};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// A copy of the repository's files in a folder of its own, removed when the test ends.
struct Copy(PathBuf);

impl Drop for Copy {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn repository() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().expect("the repository")
}

/// Every file the repository tracks, copied into a new temporary folder.
fn copy(test: &str) -> Copy {
    let from = repository();
    let to = std::env::temp_dir().join(format!(
        "schema-forge-specs-{test}-{}-{}",
        std::process::id(),
        std::time::UNIX_EPOCH.elapsed().map_or(0, |d| d.as_nanos())
    ));
    let listed = Command::new("git").args(["ls-files", "-z"]).current_dir(&from).output().expect("git ls-files");
    for path in String::from_utf8_lossy(&listed.stdout).split('\0').filter(|p| !p.is_empty()) {
        let (src, dst) = (from.join(path), to.join(path));
        if src.is_file() {
            fs::create_dir_all(dst.parent().expect("a parent")).expect("a folder");
            fs::copy(&src, &dst).expect("a copy");
        }
    }
    Copy(to)
}

impl Copy {
    fn root(&self) -> &Path {
        &self.0
    }

    /// Replaces the first `from` in a file of the copy with `to`; the test fails when the file does not hold it.
    fn edit(&self, path: &str, from: &str, to: &str) {
        let file = self.0.join(path);
        let text = fs::read_to_string(&file).unwrap_or_else(|e| panic!("{path}: {e}"));
        assert!(text.contains(from), "{path} does not hold {from:?}");
        fs::write(&file, text.replacen(from, to, 1)).expect("written");
    }

    /// Removes the part of a file from `start` to the end of the first `end` after it.
    fn cut(&self, path: &str, start: &str, end: &str) {
        let file = self.0.join(path);
        let text = fs::read_to_string(&file).expect("read");
        let a = text.find(start).unwrap_or_else(|| panic!("{path} does not hold {start:?}"));
        let b = a + text[a..].find(end).unwrap_or_else(|| panic!("{path} does not hold {end:?}")) + end.len();
        fs::write(&file, format!("{}{}", &text[..a], &text[b..])).expect("written");
    }

    fn write(&self, path: &str, text: &str) {
        let file = self.0.join(path);
        fs::create_dir_all(file.parent().expect("a parent")).expect("a folder");
        fs::write(file, text).expect("written");
    }

    fn append(&self, path: &str, text: &str) {
        let file = self.0.join(path);
        let was = fs::read_to_string(&file).expect("read");
        fs::write(file, format!("{was}{text}")).expect("written");
    }

    fn remove(&self, path: &str) {
        fs::remove_file(self.0.join(path)).expect("removed");
    }

    fn rename(&self, from: &str, to: &str) {
        fs::rename(self.0.join(from), self.0.join(to)).expect("renamed");
    }
}

/// Asserts that a finding holds every one of `needles`, printing them all when none does.
fn named(found: &[Finding], needles: &[&str]) {
    let hit = found.iter().any(|f| {
        let text = f.to_string();
        needles.iter().all(|n| text.contains(n))
    });
    assert!(hit, "no finding holds {needles:?}; the findings:\n{}", list(found));
}

fn list(found: &[Finding]) -> String {
    found.iter().map(|f| format!("  {f}")).collect::<Vec<_>>().join("\n")
}

const SF93: &str = "specs/tasks/SF-93-spec-check.xml";
const SF94: &str = "specs/tasks/SF-94-tables-interface.xml";

// --- step 1: the files ---------------------------------------------------------------------------------------------

#[test]
fn a_spec_file_that_is_not_xml_is_the_finding_not_xml() {
    let c = copy("not-xml");
    c.edit("specs/lessons.xml", "<lessons", "<lessons <<");
    named(&check(c.root()), &["specs/lessons.xml", "not XML"]);
}

#[test]
fn a_lesson_without_its_does_is_the_finding_has_no_does() {
    let c = copy("no-does");
    c.cut("specs/lessons.xml", "<does>", "</does>");
    named(&check(c.root()), &["specs/lessons.xml", "has no does"]);
}

#[test]
fn a_brief_group_with_no_path_paths_or_source_is_the_finding_has_no_files() {
    let c = copy("no-files");
    c.edit("specs/brief.xml", r#"<group name="the rules" path="specs/rules.xml">"#, r#"<group name="the rules">"#);
    named(&check(c.root()), &["specs/brief.xml", "group the rules has no files"]);
}

#[test]
fn a_guide_whose_phases_skip_a_number_is_a_finding_naming_the_guide() {
    let c = copy("phases");
    c.edit("specs/guides/engine.xml", r#"<phase n="2""#, r#"<phase n="3""#);
    named(&check(c.root()), &["specs/guides/engine.xml", "phase"]);
}

// --- step 2: the root ----------------------------------------------------------------------------------------------

#[test]
fn a_depends_naming_no_earlier_task_is_the_finding_which_is_no_earlier_task() {
    let c = copy("depends");
    c.edit(
        "specs/root.xml",
        r#"key="SF-94" name="tables interface" file="specs/tasks/SF-94-tables-interface.xml" depends="t01""#,
        r#"key="SF-94" name="tables interface" file="specs/tasks/SF-94-tables-interface.xml" depends="t10""#,
    );
    named(&check(c.root()), &["task t02 depends on t10, which is no earlier task"]);
}

#[test]
fn a_root_without_its_decisions_is_the_finding_no_decisions() {
    let c = copy("no-decisions");
    c.cut("specs/root.xml", "<decisions>", "</decisions>");
    named(&check(c.root()), &["specs/root.xml: no decisions"]);
}

#[test]
fn a_sequence_task_whose_file_is_not_named_by_its_key_is_the_finding_which_is_not_its_file_name() {
    let c = copy("file-name");
    c.rename(SF93, "specs/tasks/SF-93.xml");
    c.edit("specs/root.xml", r#"file="specs/tasks/SF-93-spec-check.xml""#, r#"file="specs/tasks/SF-93.xml""#);
    named(&check(c.root()), &["task t01 names specs/tasks/SF-93.xml, which is not its file name"]);
}

#[test]
fn an_open_decision_that_closes_before_no_task_is_the_finding_which_is_no_task() {
    let c = copy("no-task");
    c.edit(
        "specs/root.xml",
        r#"<decision id="operation-kinds" status="open" closes-before="t08">"#,
        r#"<decision id="operation-kinds" status="open" closes-before="t99">"#,
    );
    named(&check(c.root()), &["decision operation-kinds closes before t99, which is no task"]);
}

// --- step 3: open decisions ----------------------------------------------------------------------------------------

#[test]
fn a_task_file_written_while_a_decision_that_closes_before_it_is_open_is_the_finding_written_while_decision() {
    let c = copy("written-while");
    c.edit(
        "specs/root.xml",
        r#"<decision id="operation-kinds" status="open" closes-before="t08">"#,
        r#"<decision id="operation-kinds" status="open" closes-before="t02">"#,
    );
    named(&check(c.root()), &["is written while decision operation-kinds is open"]);
}

// --- step 4: the rules ---------------------------------------------------------------------------------------------

#[test]
fn a_rule_without_its_breach_is_the_finding_has_no_breach() {
    let c = copy("no-breach");
    c.cut("specs/rules.xml", "<breach>", "</breach>");
    named(&check(c.root()), &["specs/rules.xml: rule", "has no breach"]);
}

// --- step 5: a task file -------------------------------------------------------------------------------------------

#[test]
fn a_task_file_whose_gates_come_before_its_build_is_the_finding_missing_or_out_of_order() {
    let c = copy("order");
    let file = c.root().join(SF94);
    let text = fs::read_to_string(&file).expect("read");
    let (a, b) =
        (text.find("  <gates>").expect("gates"), text.find("</gates>").expect("gates end") + "</gates>\n".len());
    let gates = text[a..b].to_string();
    let without = format!("{}{}", &text[..a], &text[b..]);
    let at = without.find("  <build>").expect("build");
    fs::write(&file, format!("{}{}{}", &without[..at], gates, &without[at..])).expect("written");
    named(&check(c.root()), &[SF94, "missing or out of order"]);
}

#[test]
fn a_task_file_whose_start_carries_another_version_is_the_finding_does_not_carry_version() {
    let c = copy("version");
    c.edit(SF94, r#"name="tables interface" version="3""#, r#"name="tables interface" version="4""#);
    named(&check(c.root()), &[SF94, "start does not carry version 4"]);
}

#[test]
fn a_prove_naming_a_step_the_file_does_not_have_is_the_finding_which_is_none() {
    let c = copy("prove");
    c.edit(SF94, r#"<prove step="1">"#, r#"<prove step="99">"#);
    named(&check(c.root()), &[SF94, "prove names step 99, which is none"]);
}

#[test]
fn a_gate_without_an_expect_is_the_finding_lacks() {
    let c = copy("expect");
    c.cut(SF94, "<expect>", "</expect>");
    named(&check(c.root()), &[SF94, "lacks"]);
}

// --- step 6: quotes ------------------------------------------------------------------------------------------------

#[test]
fn a_quote_changed_by_one_word_is_the_finding_quote_not_in() {
    let c = copy("quote");
    c.edit(SF93, "so the table files always show the newest shape", "so the table files always show the oldest shape");
    named(&check(c.root()), &[SF93, "quote not in"]);
}

// --- step 7: paths -------------------------------------------------------------------------------------------------

#[test]
fn a_path_attribute_naming_a_missing_file_is_the_finding_which_does_not_exist() {
    let c = copy("path");
    c.edit(SF94, r#"path="crates/engine/src/kinds.rs""#, r#"path="nowhere/gone.rs""#);
    named(&check(c.root()), &[SF94, "names nowhere/gone.rs, which does not exist"]);
}

// --- step 8: the owners --------------------------------------------------------------------------------------------

#[test]
fn an_engine_whose_card_names_another_namespace_and_a_card_whose_version_is_not_its_migrations_are_each_a_finding_naming_the_key()
 {
    let c = copy("cards");
    c.edit("engines/mysql/owner.toml", r#"namespace = "engine_mysql""#, r#"namespace = "engine_other""#);
    c.edit("docs/owner-template/owner.toml", "version = 3 ", "version = 2 ");
    let found = check(c.root());
    named(&found, &["engines/mysql/owner.toml", "namespace"]);
    named(&found, &["docs/owner-template/owner.toml", "version"]);
}

// --- step 9: a table file ------------------------------------------------------------------------------------------

#[test]
fn a_column_line_without_its_comment_is_the_finding_has_no_comment_naming_the_line() {
    let c = copy("no-comment");
    let file = c.root().join("schema/cortex/objects.sql");
    let text = fs::read_to_string(&file).expect("read");
    let line = text.lines().find(|l| l.trim_start().starts_with("name ")).expect("the name line").to_string();
    let bare = line.split("--").next().expect("code").trim_end().to_string();
    fs::write(&file, text.replacen(&line, &bare, 1)).expect("written");
    let n = text.lines().position(|l| l == line).expect("its line") + 1;
    named(&check(c.root()), &[&format!("schema/cortex/objects.sql:{n}: column name has no comment")]);
}

#[test]
fn a_column_of_a_type_none_of_the_eight_is_the_finding_which_is_none_of_the_eight() {
    let c = copy("type");
    c.edit("schema/cortex/id_counters.sql", "last  INTEGER", "last  SMALLINT");
    named(
        &check(c.root()),
        &["schema/cortex/id_counters.sql", "column last has the type SMALLINT, which is none of the eight"],
    );
}

#[test]
fn a_table_outside_its_owner_s_namespace_or_not_named_as_its_file_is_a_finding_naming_the_file() {
    let c = copy("namespace");
    c.edit("schema/cortex/turns.sql", "CREATE TABLE cortex.turns (", "CREATE TABLE public.turns (");
    named(&check(c.root()), &["schema/cortex/turns.sql"]);
}

#[test]
fn a_database_comment_that_differs_from_its_column_s_comment_is_the_finding_is_not_its_file_s() {
    let c = copy("comment");
    c.edit(
        "schema/cortex/objects.sql",
        "COMMENT ON COLUMN cortex.objects.name IS 'orders';",
        "COMMENT ON COLUMN cortex.objects.name IS 'the orders';",
    );
    named(&check(c.root()), &["schema/cortex/objects.sql", "the database's comment on name is not its file's"]);
}

#[test]
fn an_engine_table_referring_to_another_engine_s_table_is_the_finding_which_is_not_its_own_or_the_cortex_s() {
    let c = copy("refers");
    c.edit(
        "engines/mysql/schema/table_options.sql",
        "REFERENCES cortex.objects (id)",
        "REFERENCES engine_quill.record_options (id)",
    );
    named(&check(c.root()), &["engines/mysql/schema/table_options.sql", "which is not its own or the cortex's"]);
}

#[test]
fn a_table_whose_primary_key_is_not_the_one_column_id_is_the_finding_not_the_one_column_id() {
    let c = copy("primary-key");
    c.edit("schema/cortex/subject_areas.sql", "NOT NULL PRIMARY KEY CHECK", "NOT NULL CHECK");
    named(&check(c.root()), &["schema/cortex/subject_areas.sql", "not the one column id"]);
}

// --- step 10: rules ------------------------------------------------------------------------------------------------

#[test]
fn a_rule_whose_view_is_not_named_broken_and_its_rule_is_a_finding_naming_the_file() {
    let c = copy("rule-view");
    let path = "schema/cortex/rules/one-program-part.sql";
    let file = c.root().join(path);
    let text = fs::read_to_string(&file).expect("read");
    fs::write(&file, text.replace("cortex.broken_one_program_part", "cortex.one_program_part")).expect("written");
    named(&check(c.root()), &[path]);
}

// --- step 11: seeds ------------------------------------------------------------------------------------------------

#[test]
fn a_seed_that_updates_a_row_is_the_finding_a_seed_writes_only_new_rows() {
    let c = copy("seed");
    c.edit(
        "schema/workspace/seeds/parameters.sql",
        "ON CONFLICT (id) DO NOTHING",
        "ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value",
    );
    named(&check(c.root()), &["schema/workspace/seeds/parameters.sql", "a seed writes only new rows"]);
}

// --- step 12: migrations -------------------------------------------------------------------------------------------

#[test]
fn a_migration_numbered_with_a_gap_is_the_finding_migrations_not_numbered() {
    let c = copy("gap");
    c.rename(
        "docs/owner-template/schema/migrations/3_compaction_policy_drop_old.sql",
        "docs/owner-template/schema/migrations/4_compaction_policy_drop_old.sql",
    );
    named(&check(c.root()), &["migrations not numbered"]);
}

// --- step 13: loads on PostgreSQL ----------------------------------------------------------------------------------

#[test]
fn in_docker_a_table_file_postgresql_refuses_is_the_finding_does_not_load_with_postgresql_s_message() {
    let c = copy("refused");
    c.edit("schema/cortex/objects.sql", "CHECK (length(name) >= 1)", "CHECK (lengthx(name) >= 1)");
    named(&load(c.root()), &["schema/cortex/objects.sql: does not load:", "lengthx"]);
}

#[test]
fn in_docker_a_rule_that_lists_a_row_of_a_new_database_is_the_finding_lists_rows_of_a_new_database() {
    let c = copy("always-broken");
    c.write(
        "schema/cortex/rules/always-broken.sql",
        "-- always-broken: A rule no new database keeps. Owner: cortex.\n\
         CREATE VIEW cortex.broken_always_broken AS\n\
         SELECT 'always-broken' AS rule, 'x'::text AS id;\n\n\
         COMMENT ON VIEW cortex.broken_always_broken IS 'A rule no new database keeps.';\n",
    );
    named(&load(c.root()), &["rule always-broken lists rows of a new database"]);
}

#[test]
fn in_docker_a_seed_whose_rows_take_a_new_id_each_time_it_is_applied_is_the_finding_changes_the_database() {
    let c = copy("seed-again");
    c.append(
        "schema/workspace/seeds/parameters.sql",
        "\nINSERT INTO workspace.parameters (id, value, about) VALUES \
         ('product.' || translate(substr(md5(random()::text), 1, 8), '0123456789', 'ghijklmnop'), '\"x\"', 'a new row each time') \
         ON CONFLICT (id) DO NOTHING;\n",
    );
    named(&load(c.root()), &["schema/workspace/seeds/parameters.sql: applying it again changes the database"]);
}

#[test]
fn in_docker_the_template_with_its_last_migration_removed_is_the_finding_its_versions_do_not_give_its_files() {
    let c = copy("versions");
    c.remove("docs/owner-template/schema/migrations/3_compaction_policy_drop_old.sql");
    named(&load(c.root()), &["its versions do not give its files"]);
}

#[test]
fn in_docker_a_role_grant_that_lets_sf_service_create_a_table_is_the_finding_sf_service_can_change_the_schema() {
    let c = copy("grant");
    c.append("schema/cortex/grant_roles.sql", "\nGRANT CREATE ON SCHEMA cortex TO sf_service;\n");
    named(&load(c.root()), &["sf_service can change the schema"]);
}

#[test]
fn in_docker_a_table_file_given_an_index_its_dump_does_not_hold_is_the_finding_drifted_from_its_dump() {
    let c = copy("drift");
    c.append("schema/cortex/subject_areas.sql", "\nCREATE INDEX drift_probe ON cortex.subject_areas (id);\n");
    named(&load(c.root()), &["schema/dump/", "the database drifted from its dump", "drift_probe"]);
}

// --- step 14: the lock ---------------------------------------------------------------------------------------------

#[test]
fn a_locked_table_file_changed_by_one_byte_is_the_finding_changed_outside_a_design_session() {
    let c = copy("byte");
    c.append("schema/cortex/objects.sql", "\n");
    named(&check(c.root()), &["schema/cortex/objects.sql: changed outside a design session"]);
}

#[test]
fn a_table_file_added_and_not_locked_is_the_finding_not_locked() {
    let c = copy("unlocked");
    c.write("schema/cortex/extra.sql", "-- cortex.extra: a table no design session locked. Owner: cortex.\n");
    named(&check(c.root()), &["schema/cortex/extra.sql: not locked"]);
}
