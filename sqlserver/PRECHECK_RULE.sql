/* ===============================================================================
   Relative Path : sqlserver/PRECHECK_RULE.sql

   用途     : 核算项「执行前校验」规则配置与执行留痕
   设计要点 :
     1. 规则元数据（名称/后果/建议/级别）放配置表，**不进 SQL**；
     2. 规则 SQL 以 git 文件为源（script_file），库内 sql_text 为执行快照 + sql_hash 防漂移；
     3. 引擎契约只有 3 条：只读 SELECT 含 {year}/{month}、行数>0 即命中、行数≤max_rows；
        **不强制任何输出列名**，明细原样展示。
   命名规范 : 全小写 + 下划线；数值统一 DECIMAL(18,8)（计数/时长用 INT 除外）
   幂等     : 表/索引不存在才创建，可重复执行
   执行说明 : 本脚本只建结构，不写测试数据；示例规则见文件末尾（默认注释掉）
   =============================================================================== */

SET NOCOUNT ON;

/* ---------- 1. 规则配置 ---------- */
IF OBJECT_ID('dbo.dim_precheck_rule', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dim_precheck_rule (
        id              BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        rule_name       NVARCHAR(128)       NOT NULL,              -- 规则名（页面标题）
        script_code     NVARCHAR(64)        NOT NULL,              -- 归属核算项编码（SCRIPT_NAME）
        script_name     NVARCHAR(128)       NULL,                   -- 核算项名称（便于展示）
        script_file     NVARCHAR(255)       NULL,                   -- git 路径：一次分配/医疗服务项目执行积分.sql
        rule_file       NVARCHAR(255)       NULL,                   -- 规则 SQL 路径：precheck/xxx.sql
        severity        NVARCHAR(8)         NOT NULL DEFAULT 'BLOCK', -- BLOCK / WARN
        message_detail  NVARCHAR(512)       NULL,                   -- 后果说明（所有命中行共用）
        suggestion      NVARCHAR(512)       NULL,                   -- 处理建议
        sql_text        NVARCHAR(MAX)       NULL,                   -- 执行快照（由文件灌入）
        sql_hash        VARCHAR(64)         NULL,                   -- 文件内容哈希，防漂移
        timeout_sec     INT                 NOT NULL DEFAULT 30,
        max_rows        INT                 NOT NULL DEFAULT 200,
        enabled         INT                 NOT NULL DEFAULT 1,
        sort_no         INT                 NOT NULL DEFAULT 0,
        valid_from      DATETIME2(3)        NULL,                   -- 规则生效起（可空=长期）
        valid_to        DATETIME2(3)        NULL,                   -- 规则生效止（可空=长期）
        remark          NVARCHAR(255)       NULL,
        create_user     DECIMAL(20,0)       NULL,
        create_time     DATETIME2(3)        NOT NULL DEFAULT SYSDATETIME(),
        update_user     DECIMAL(20,0)       NULL,
        update_time     DATETIME2(3)        NULL,
        delete_flag     INT                 NOT NULL DEFAULT 0
    );

    CREATE INDEX ix_pred_rule_script ON dbo.dim_precheck_rule (script_code, enabled, sort_no);
    PRINT N'[1] 已创建 dim_precheck_rule';
END
ELSE PRINT N'[1] dim_precheck_rule 已存在，跳过';

/* ---------- 2. 一次执行批次（点一次生成/预检 = 一个批次） ---------- */
IF OBJECT_ID('dbo.log_precheck_batch', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.log_precheck_batch (
        id            BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        batch_no      VARCHAR(32)        NOT NULL,      -- 业务批次号（时间戳+序号，便于对账）
        calc_year     INT                NOT NULL,
        calc_month    INT                NOT NULL,
        plan_id       DECIMAL(20,0)      NULL,
        stage         NVARCHAR(16)       NOT NULL,      -- DRYRUN=预检 / EXECUTE=生成时校验
        result        NVARCHAR(16)       NOT NULL,      -- PASS / WARN_HIT / BLOCK_HIT / ERROR
        rule_total    INT                NOT NULL DEFAULT 0,
        rule_hit      INT                NOT NULL DEFAULT 0,
        duration_ms   INT                NOT NULL DEFAULT 0,
        operator_id   DECIMAL(20,0)      NULL,
        operator_no   NVARCHAR(64)       NULL,
        operator_name NVARCHAR(64)       NULL,
        run_time      DATETIME2(3)       NOT NULL DEFAULT SYSDATETIME()
    );

    CREATE UNIQUE INDEX ux_pred_batch_no ON dbo.log_precheck_batch (batch_no);
    CREATE INDEX ix_pred_batch_period ON dbo.log_precheck_batch (calc_year, calc_month, run_time DESC);
    PRINT N'[2] 已创建 log_precheck_batch';
END
ELSE PRINT N'[2] log_precheck_batch 已存在，跳过';

/* ---------- 3. 单条规则执行明细/结果 ---------- */
IF OBJECT_ID('dbo.log_precheck_run', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.log_precheck_run (
        id            BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        batch_id      BIGINT             NOT NULL,
        rule_id       BIGINT             NULL,
        rule_name     NVARCHAR(128)      NULL,          -- 快照：规则改名后历史仍可读
        script_code   NVARCHAR(64)       NULL,
        severity      NVARCHAR(8)        NULL,
        result        NVARCHAR(16)       NOT NULL,      -- PASS / HIT / ERROR / TIMEOUT / SKIPPED
        hit_count     INT                NOT NULL DEFAULT 0,
        duration_ms   INT                NOT NULL DEFAULT 0,
        error_msg     NVARCHAR(512)      NULL,
        detail_json   NVARCHAR(MAX)      NULL,          -- 前 max_rows 行明细（供页面展开/导出）
        waived        INT                NOT NULL DEFAULT 0,   -- 1=WARN 命中后人工放行
        waive_reason  NVARCHAR(255)      NULL,
        waive_user    DECIMAL(20,0)      NULL,
        waive_time    DATETIME2(3)       NULL,
        run_time      DATETIME2(3)       NOT NULL DEFAULT SYSDATETIME()
    );

    CREATE INDEX ix_pred_run_batch ON dbo.log_precheck_run (batch_id);
    CREATE INDEX ix_pred_run_rule  ON dbo.log_precheck_run (rule_id, run_time DESC);
    CREATE INDEX ix_pred_run_script ON dbo.log_precheck_run (script_code, run_time DESC);
    PRINT N'[3] 已创建 log_precheck_run';
END
ELSE PRINT N'[3] log_precheck_run 已存在，跳过';

/* ---------- 4. 示例规则（默认不插入，确认后自行执行） ----------
INSERT INTO dbo.dim_precheck_rule
    (rule_name, script_code, script_name, script_file, rule_file, severity,
     message_detail, suggestion, sql_text, timeout_sec, max_rows, enabled, sort_no, remark, create_time)
VALUES
    (N'医技护执行比例未配置',
     N'ITEM_MED_SVC_EXEC_SCORE',
     N'医疗服务项目执行积分',
     N'一次分配/医疗服务项目执行积分.sql',
     N'precheck/医疗服务项目执行积分_医技护执行比例未配置.sql',
     N'BLOCK',
     N'该科室+项目在 DIM_DEPT_ITEM_EXEC_RATIO 中无生效配置，执行积分按 0 计，相关工作量将漏算。',
     N'请在「各科室收费项目医技护执行比例」补齐配置后重新执行校验。',
     NULL,          -- sql_text 由「同步规则文件」功能灌入
     30, 200, 1, 10, N'示例规则：执行前拦截未配置比例', SYSDATETIME());
   ------------------------------------------------------------------------- */

/* ---------- 5. 核对 ---------- */
SELECT 'dim_precheck_rule' AS tbl, COUNT(1) AS rows_cnt FROM dbo.dim_precheck_rule
UNION ALL SELECT 'log_precheck_batch', COUNT(1) FROM dbo.log_precheck_batch
UNION ALL SELECT 'log_precheck_run', COUNT(1) FROM dbo.log_precheck_run;
