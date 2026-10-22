-- Dolt schema of a fresh bd v1.3.0 embedded workspace (schema_migrations version 66).
-- Generated with: dolt schema export   (dolt 2.5.1, against .beads/embeddeddolt/<db>)
-- Upstream: https://github.com/gastownhall/beads (MIT). Views appended at the end.

CREATE TABLE `bd_events_journal` (
  `seq` bigint NOT NULL,
  `ts` datetime NOT NULL,
  `op` varchar(32) NOT NULL,
  `issue_id` varchar(255) NOT NULL,
  `issue_json` longtext,
  `dep_json` longtext,
  `comment_json` longtext,
  `actor` varchar(255) NOT NULL DEFAULT '',
  PRIMARY KEY (`seq`),
  KEY `idx_bd_events_journal_issue` (`issue_id`),
  KEY `idx_bd_events_journal_ts` (`ts`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `bd_events_seq` (
  `id` int NOT NULL,
  `next_seq` bigint NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `child_counters` (
  `parent_id` varchar(255) NOT NULL,
  `last_child` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`parent_id`),
  CONSTRAINT `fk_counter_parent` FOREIGN KEY (`parent_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `comments` (
  `id` char(36) NOT NULL,
  `issue_id` varchar(255) NOT NULL,
  `author` varchar(255) NOT NULL,
  `text` longtext NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_comments_created_at` (`created_at`),
  KEY `idx_comments_issue` (`issue_id`),
  KEY `idx_comments_issue_created_id` (`issue_id`,`created_at`,`id`),
  CONSTRAINT `fk_comments_issue` FOREIGN KEY (`issue_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `compaction_snapshots` (
  `id` char(36) NOT NULL,
  `issue_id` varchar(255) NOT NULL,
  `compaction_level` int NOT NULL,
  `snapshot_json` blob NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_comp_snap_issue` (`issue_id`,`compaction_level`,`created_at`),
  CONSTRAINT `fk_comp_snap_issue` FOREIGN KEY (`issue_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `config` (
  `key` varchar(255) NOT NULL,
  `value` text NOT NULL,
  PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `custom_statuses` (
  `name` varchar(64) NOT NULL,
  `category` varchar(32) NOT NULL DEFAULT 'unspecified',
  PRIMARY KEY (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `custom_types` (
  `name` varchar(64) NOT NULL,
  PRIMARY KEY (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `dependencies` (
  `id` char(36) NOT NULL,
  `issue_id` varchar(255) NOT NULL,
  `type` varchar(32) NOT NULL DEFAULT 'blocks',
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `created_by` varchar(255) NOT NULL,
  `metadata` json DEFAULT (json_object()),
  `thread_id` varchar(255) DEFAULT '',
  `depends_on_issue_id` varchar(255),
  `depends_on_wisp_id` varchar(255),
  `depends_on_external` varchar(255),
  PRIMARY KEY (`id`),
  KEY `idx_dep_external_target` (`depends_on_external`),
  KEY `idx_dep_issue_target` (`depends_on_issue_id`),
  KEY `idx_dep_type_external` (`type`,`depends_on_external`),
  KEY `idx_dep_type_issue` (`type`,`depends_on_issue_id`),
  KEY `idx_dep_type_wisp` (`type`,`depends_on_wisp_id`),
  KEY `idx_dep_wisp_target` (`depends_on_wisp_id`),
  KEY `idx_dependencies_issue` (`issue_id`),
  KEY `idx_dependencies_thread` (`thread_id`),
  UNIQUE KEY `uk_dep_external_target` (`issue_id`,`depends_on_external`),
  UNIQUE KEY `uk_dep_issue_target` (`issue_id`,`depends_on_issue_id`),
  UNIQUE KEY `uk_dep_wisp_target` (`issue_id`,`depends_on_wisp_id`),
  CONSTRAINT `fk_dep_issue` FOREIGN KEY (`issue_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_dep_issue_target` FOREIGN KEY (`depends_on_issue_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `ck_dep_one_target` CHECK (((((NOT(`depends_on_issue_id` IS NULL)) + (NOT(`depends_on_wisp_id` IS NULL))) + (NOT(`depends_on_external` IS NULL))) = 1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `events` (
  `issue_id` varchar(255) NOT NULL,
  `event_type` varchar(32) NOT NULL,
  `actor` varchar(255) NOT NULL,
  `old_value` longtext,
  `new_value` longtext,
  `comment` text,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `id` char(36) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_events_created_at` (`created_at`),
  KEY `idx_events_issue` (`issue_id`),
  CONSTRAINT `fk_events_issue` FOREIGN KEY (`issue_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `federation_peers` (
  `name` varchar(255) NOT NULL,
  `remote_url` varchar(1024) NOT NULL,
  `username` varchar(255),
  `password_encrypted` blob,
  `sovereignty` varchar(8) DEFAULT '',
  `last_sync` datetime,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`name`),
  KEY `idx_federation_peers_sovereignty` (`sovereignty`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `ignored_schema_migrations` (
  `version` int NOT NULL,
  `applied_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `content_hash` char(64),
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `interactions` (
  `id` varchar(32) NOT NULL,
  `kind` varchar(64) NOT NULL,
  `created_at` datetime NOT NULL,
  `actor` varchar(255),
  `issue_id` varchar(255),
  `model` varchar(255),
  `prompt` text,
  `response` text,
  `error` text,
  `tool_name` varchar(255),
  `exit_code` int,
  `parent_id` varchar(32),
  `label` varchar(64),
  `reason` text,
  `extra` json,
  PRIMARY KEY (`id`),
  KEY `idx_interactions_created_at` (`created_at`),
  KEY `idx_interactions_issue_id` (`issue_id`),
  KEY `idx_interactions_kind` (`kind`),
  KEY `idx_interactions_parent_id` (`parent_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `issue_counter` (
  `prefix` varchar(255) NOT NULL,
  `last_id` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`prefix`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `issue_snapshots` (
  `id` char(36) NOT NULL,
  `issue_id` varchar(255) NOT NULL,
  `snapshot_time` datetime NOT NULL,
  `compaction_level` int NOT NULL,
  `original_size` int NOT NULL,
  `compressed_size` int NOT NULL,
  `original_content` text NOT NULL,
  `archived_events` text,
  PRIMARY KEY (`id`),
  KEY `idx_snapshots_issue` (`issue_id`),
  KEY `idx_snapshots_level` (`compaction_level`),
  CONSTRAINT `fk_snapshots_issue` FOREIGN KEY (`issue_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `issues` (
  `id` varchar(255) NOT NULL,
  `content_hash` varchar(64),
  `title` varchar(500) NOT NULL,
  `description` longtext NOT NULL,
  `design` longtext NOT NULL,
  `acceptance_criteria` longtext NOT NULL,
  `notes` longtext NOT NULL,
  `status` varchar(32) NOT NULL DEFAULT 'open',
  `priority` int NOT NULL DEFAULT '2',
  `issue_type` varchar(32) NOT NULL DEFAULT 'task',
  `assignee` varchar(255),
  `estimated_minutes` int,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `created_by` varchar(255) DEFAULT '',
  `owner` varchar(255) DEFAULT '',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `closed_at` datetime,
  `closed_by_session` varchar(255) DEFAULT '',
  `external_ref` varchar(255),
  `spec_id` varchar(1024),
  `compaction_level` int DEFAULT '0',
  `compacted_at` datetime,
  `compacted_at_commit` varchar(64),
  `original_size` int,
  `sender` varchar(255) DEFAULT '',
  `ephemeral` tinyint(1) DEFAULT '0',
  `wisp_type` varchar(32) DEFAULT '',
  `pinned` tinyint(1) DEFAULT '0',
  `is_template` tinyint(1) DEFAULT '0',
  `mol_type` varchar(32) DEFAULT '',
  `work_type` varchar(32) DEFAULT 'mutex',
  `source_system` varchar(255) DEFAULT '',
  `metadata` json DEFAULT (json_object()),
  `source_repo` varchar(512) DEFAULT '',
  `close_reason` longtext DEFAULT '',
  `event_kind` varchar(32) DEFAULT '',
  `actor` varchar(255) DEFAULT '',
  `target` varchar(255) DEFAULT '',
  `payload` text DEFAULT '',
  `await_type` varchar(32) DEFAULT '',
  `await_id` varchar(255) DEFAULT '',
  `timeout_ns` bigint DEFAULT '0',
  `waiters` text DEFAULT '',
  `hook_bead` varchar(255) DEFAULT '',
  `role_bead` varchar(255) DEFAULT '',
  `agent_state` varchar(32) DEFAULT '',
  `last_activity` datetime,
  `role_type` varchar(32) DEFAULT '',
  `rig` varchar(255) DEFAULT '',
  `due_at` datetime,
  `defer_until` datetime,
  `no_history` tinyint(1) DEFAULT '0',
  `started_at` datetime,
  `is_blocked` tinyint(1) NOT NULL DEFAULT '0',
  `row_lock` bigint NOT NULL DEFAULT '0',
  `storage_class` varchar(16),
  PRIMARY KEY (`id`),
  KEY `idx_issues_assignee` (`assignee`),
  KEY `idx_issues_created_at` (`created_at`),
  KEY `idx_issues_defer_until` (`defer_until`),
  KEY `idx_issues_external_ref` (`external_ref`),
  KEY `idx_issues_is_blocked` (`is_blocked`,`status`),
  KEY `idx_issues_issue_type` (`issue_type`),
  KEY `idx_issues_priority` (`priority`),
  KEY `idx_issues_spec_id` (`spec_id`),
  KEY `idx_issues_status_updated_at` (`status`,`updated_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `labels` (
  `issue_id` varchar(255) NOT NULL,
  `label` varchar(255) NOT NULL,
  PRIMARY KEY (`issue_id`,`label`),
  KEY `idx_labels_label` (`label`),
  CONSTRAINT `fk_labels_issue` FOREIGN KEY (`issue_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `leases` (
  `issue_id` varchar(255) NOT NULL,
  `holder` varchar(255) NOT NULL,
  `granted_at` datetime NOT NULL,
  `lease_expires_at` datetime NOT NULL,
  `heartbeat_at` datetime NOT NULL,
  `granted_node` varchar(255) NOT NULL DEFAULT '',
  PRIMARY KEY (`issue_id`),
  KEY `idx_leases_expires` (`lease_expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `local_metadata` (
  `key` varchar(255) NOT NULL,
  `value` text NOT NULL DEFAULT '',
  PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `metadata` (
  `key` varchar(255) NOT NULL,
  `value` text NOT NULL,
  PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `provenance_events` (
  `id` char(36) NOT NULL,
  `issue_id` varchar(255) NOT NULL,
  `kind` varchar(32) NOT NULL,
  `actor` varchar(255),
  `ref` varchar(255),
  `ref_kind` varchar(32),
  `payload` text,
  `source` varchar(64) NOT NULL,
  `occurred_at` datetime,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_provenance_events_issue_occurred` (`issue_id`,`occurred_at`),
  KEY `idx_provenance_events_kind` (`kind`),
  KEY `idx_provenance_events_ref` (`ref`),
  CONSTRAINT `fk_provenance_events_issue` FOREIGN KEY (`issue_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `repo_mtimes` (
  `repo_path` varchar(512) NOT NULL,
  `jsonl_path` varchar(512) NOT NULL,
  `mtime_ns` bigint NOT NULL,
  `last_checked` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`repo_path`),
  KEY `idx_repo_mtimes_checked` (`last_checked`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `routes` (
  `prefix` varchar(32) NOT NULL,
  `path` varchar(512) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`prefix`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `schema_migrations` (
  `version` int NOT NULL,
  `content_hash` char(64),
  PRIMARY KEY (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `wisp_child_counters` (
  `parent_id` varchar(255) NOT NULL,
  `last_child` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`parent_id`),
  CONSTRAINT `fk_wisp_child_counters_parent` FOREIGN KEY (`parent_id`) REFERENCES `wisps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `wisp_comments` (
  `id` char(36) NOT NULL,
  `issue_id` varchar(255) NOT NULL,
  `author` varchar(255) DEFAULT '',
  `text` longtext NOT NULL,
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_wisp_comments_issue` (`issue_id`),
  KEY `idx_wisp_comments_issue_created_id` (`issue_id`,`created_at`,`id`),
  CONSTRAINT `fk_wisp_comments_issue` FOREIGN KEY (`issue_id`) REFERENCES `wisps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `wisp_dependencies` (
  `id` char(36) NOT NULL,
  `issue_id` varchar(255) NOT NULL,
  `depends_on_issue_id` varchar(255),
  `depends_on_wisp_id` varchar(255),
  `depends_on_external` varchar(255),
  `type` varchar(32) NOT NULL DEFAULT 'blocks',
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  `created_by` varchar(255) DEFAULT '',
  `metadata` json DEFAULT (json_object()),
  `thread_id` varchar(255) DEFAULT '',
  PRIMARY KEY (`id`),
  KEY `fk_wisp_dep_issue_target` (`depends_on_issue_id`),
  KEY `fk_wisp_dep_wisp_target` (`depends_on_wisp_id`),
  KEY `idx_wisp_dep_type` (`type`),
  KEY `idx_wisp_dep_type_external` (`type`,`depends_on_external`),
  KEY `idx_wisp_dep_type_issue` (`type`,`depends_on_issue_id`),
  KEY `idx_wisp_dep_type_wisp` (`type`,`depends_on_wisp_id`),
  UNIQUE KEY `uk_wisp_dep_external_target` (`issue_id`,`depends_on_external`),
  UNIQUE KEY `uk_wisp_dep_issue_target` (`issue_id`,`depends_on_issue_id`),
  UNIQUE KEY `uk_wisp_dep_wisp_target` (`issue_id`,`depends_on_wisp_id`),
  CONSTRAINT `fk_wisp_dep_issue` FOREIGN KEY (`issue_id`) REFERENCES `wisps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_wisp_dep_issue_target` FOREIGN KEY (`depends_on_issue_id`) REFERENCES `issues` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_wisp_dep_wisp_target` FOREIGN KEY (`depends_on_wisp_id`) REFERENCES `wisps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `ck_wisp_dep_one_target` CHECK (((((NOT(`depends_on_issue_id` IS NULL)) + (NOT(`depends_on_wisp_id` IS NULL))) + (NOT(`depends_on_external` IS NULL))) = 1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `wisp_events` (
  `id` char(36) NOT NULL,
  `issue_id` varchar(255) NOT NULL,
  `event_type` varchar(32) NOT NULL,
  `actor` varchar(255) DEFAULT '',
  `old_value` longtext DEFAULT '',
  `new_value` longtext DEFAULT '',
  `comment` text DEFAULT '',
  `created_at` datetime DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_wisp_events_created_at` (`created_at`),
  KEY `idx_wisp_events_issue` (`issue_id`),
  CONSTRAINT `fk_wisp_events_issue` FOREIGN KEY (`issue_id`) REFERENCES `wisps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `wisp_labels` (
  `issue_id` varchar(255) NOT NULL,
  `label` varchar(255) NOT NULL,
  PRIMARY KEY (`issue_id`,`label`),
  KEY `idx_wisp_labels_label` (`label`),
  CONSTRAINT `fk_wisp_labels_issue` FOREIGN KEY (`issue_id`) REFERENCES `wisps` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE `wisps` (
  `id` varchar(255) NOT NULL,
  `content_hash` varchar(64),
  `title` varchar(500) NOT NULL,
  `description` longtext NOT NULL DEFAULT '',
  `design` longtext NOT NULL DEFAULT '',
  `acceptance_criteria` longtext NOT NULL DEFAULT '',
  `notes` longtext NOT NULL DEFAULT '',
  `status` varchar(32) NOT NULL DEFAULT 'open',
  `priority` int NOT NULL DEFAULT '2',
  `issue_type` varchar(32) NOT NULL DEFAULT 'task',
  `assignee` varchar(255),
  `estimated_minutes` int,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `created_by` varchar(255) DEFAULT '',
  `owner` varchar(255) DEFAULT '',
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `closed_at` datetime,
  `closed_by_session` varchar(255) DEFAULT '',
  `external_ref` varchar(255),
  `spec_id` varchar(1024),
  `compaction_level` int DEFAULT '0',
  `compacted_at` datetime,
  `compacted_at_commit` varchar(64),
  `original_size` int,
  `sender` varchar(255) DEFAULT '',
  `ephemeral` tinyint(1) DEFAULT '0',
  `wisp_type` varchar(32) DEFAULT '',
  `pinned` tinyint(1) DEFAULT '0',
  `is_template` tinyint(1) DEFAULT '0',
  `mol_type` varchar(32) DEFAULT '',
  `work_type` varchar(32) DEFAULT 'mutex',
  `source_system` varchar(255) DEFAULT '',
  `metadata` json DEFAULT (json_object()),
  `source_repo` varchar(512) DEFAULT '',
  `close_reason` longtext DEFAULT '',
  `event_kind` varchar(32) DEFAULT '',
  `actor` varchar(255) DEFAULT '',
  `target` varchar(255) DEFAULT '',
  `payload` text DEFAULT '',
  `await_type` varchar(32) DEFAULT '',
  `await_id` varchar(255) DEFAULT '',
  `timeout_ns` bigint DEFAULT '0',
  `waiters` text DEFAULT '',
  `hook_bead` varchar(255) DEFAULT '',
  `role_bead` varchar(255) DEFAULT '',
  `agent_state` varchar(32) DEFAULT '',
  `last_activity` datetime,
  `role_type` varchar(32) DEFAULT '',
  `rig` varchar(255) DEFAULT '',
  `due_at` datetime,
  `defer_until` datetime,
  `no_history` tinyint(1) DEFAULT '0',
  `started_at` datetime,
  `row_lock` bigint NOT NULL DEFAULT '0',
  `storage_class` varchar(16),
  `is_blocked` tinyint(1) NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`),
  KEY `idx_wisps_assignee` (`assignee`),
  KEY `idx_wisps_created_at` (`created_at`),
  KEY `idx_wisps_defer_until` (`defer_until`),
  KEY `idx_wisps_external_ref` (`external_ref`),
  KEY `idx_wisps_is_blocked` (`is_blocked`,`status`),
  KEY `idx_wisps_issue_type` (`issue_type`),
  KEY `idx_wisps_priority` (`priority`),
  KEY `idx_wisps_spec_id` (`spec_id`),
  KEY `idx_wisps_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- ---------------------------------------------------------------------------
-- Views (legacy; bd 1.3.0 computes readiness from issues.is_blocked at runtime)
-- ---------------------------------------------------------------------------
CREATE VIEW `blocked_issues` AS
WITH done_frozen AS (
    SELECT name FROM custom_statuses WHERE category IN ('done', 'frozen')
)
SELECT
    i.*,
    (SELECT COUNT(*)
     FROM dependencies d
     WHERE d.issue_id = i.id
       AND d.type = 'blocks'
       AND EXISTS (
         SELECT 1 FROM issues blocker
         WHERE blocker.id = d.depends_on_issue_id
           AND blocker.status NOT IN ('closed', 'pinned')
           AND blocker.status NOT IN (SELECT name FROM done_frozen)
       )
    ) as blocked_by_count
FROM issues i
WHERE i.status NOT IN ('closed', 'pinned')
  AND i.status NOT IN (SELECT name FROM done_frozen)
  AND EXISTS (
    SELECT 1 FROM dependencies d
    WHERE d.issue_id = i.id
      AND d.type = 'blocks'
      AND EXISTS (
        SELECT 1 FROM issues blocker
        WHERE blocker.id = d.depends_on_issue_id
          AND blocker.status NOT IN ('closed', 'pinned')
          AND blocker.status NOT IN (SELECT name FROM done_frozen)
      )
  );

CREATE VIEW `ready_issues` AS
WITH RECURSIVE
  blocked_directly AS (
    SELECT DISTINCT d.issue_id
    FROM dependencies d
    WHERE d.type = 'blocks'
      AND EXISTS (
        SELECT 1 FROM issues blocker
        WHERE blocker.id = d.depends_on_issue_id
          AND blocker.status NOT IN ('closed', 'pinned')
      )
  ),
  blocked_transitively AS (
    SELECT issue_id, 0 as depth
    FROM blocked_directly
    UNION ALL
    SELECT d.issue_id, bt.depth + 1
    FROM blocked_transitively bt
    JOIN dependencies d ON d.depends_on_issue_id = bt.issue_id
    WHERE d.type = 'parent-child'
      AND bt.depth < 50
  )
SELECT i.*
FROM issues i
LEFT JOIN blocked_transitively bt ON bt.issue_id = i.id
WHERE (
    i.status = 'open'
    OR i.status IN (SELECT name FROM custom_statuses WHERE category = 'active')
  )
  AND (i.ephemeral = 0 OR i.ephemeral IS NULL)
  AND bt.issue_id IS NULL
  AND (i.defer_until IS NULL OR i.defer_until <= UTC_TIMESTAMP())
  AND NOT EXISTS (
    SELECT 1 FROM dependencies d_parent
    JOIN issues parent ON parent.id = d_parent.depends_on_issue_id
    WHERE d_parent.issue_id = i.id
      AND d_parent.type = 'parent-child'
      AND parent.defer_until IS NOT NULL
      AND parent.defer_until > UTC_TIMESTAMP()
  );

