WITH
/* 0) بيانات القرض */
loan_info AS (
    SELECT DEBT_RECORD_CODE, CUSTNO, BRANCH_NAME, PRODUCT_CODE, PRODUCT_NAME, LOAN_FLAG, LOAN_STATUS
    FROM (
        SELECT
            L.DEBT_RECORD_CODE,
            L.CUSTNO,
            B.ANAME       AS BRANCH_NAME,
            L.DEBT_TYPE   AS PRODUCT_CODE,
            P.ANAME       AS PRODUCT_NAME,
            L.FLAG        AS LOAN_FLAG,
            CASE L.FLAG
                WHEN 9  THEN 'قائم'
                WHEN 50 THEN 'مغلق سداد عادي'
                ELSE         'Other (' || L.FLAG || ')'
            END           AS LOAN_STATUS,
            ROW_NUMBER() OVER (PARTITION BY L.DEBT_RECORD_CODE ORDER BY L.BUSDATE DESC) AS RN
        FROM ERADA.FDEBTSM_MICRO L
        LEFT JOIN ERADA.FBRANCH B
            ON L.BRCODE = B.BRCODE
        LEFT JOIN ERADA.FPROD_PARAM_LOAN_MICRO P
            ON  L.DEBT_TYPE  = P.LOAN_TYPE
            AND P.LAYER_CODE = 0
    )
    WHERE RN = 1
      AND PRODUCT_CODE < 500
),

loan_cust AS (
    SELECT DEBT_RECORD_CODE, MAX(CUSTNO) AS CUSTNO
    FROM ERADA.FDEBTSM_MICRO
    GROUP BY DEBT_RECORD_CODE
),

loan_span AS (
    SELECT DEBT_RECORD_CODE, MIN(PRIMIUM_DATE) AS FIRST_DUE, MAX(PRIMIUM_DATE) AS LAST_DUE
    FROM ERADA.FDEBTS_PRIMIUM_MICRO
    GROUP BY DEBT_RECORD_CODE
),

/* قروض اتعملها سداد معجل (FLAG = 13) في أي وقت
   بتدخل في التوزيع عشان فلوسها تروحلها، وبتتشال من النتيجة النهائية */
early_paid AS (
    SELECT DISTINCT DEBT_RECORD_CODE
    FROM ERADA.FDEBTSM_MICRO
    WHERE FLAG = 13
),

/* 1) الترانزكشنز اللي ليها رقم قرض */
trx_loan AS (
    SELECT DEBT_RECORD_CODE, TRUNC(BUSDATE) AS TRX_DATE, PAY_AMT AS AMT, 'Elec' AS SRC
    FROM ERADA.FPAMENT_INFO_MF
    UNION ALL
    SELECT DEBT_RECORD_CODE, TRUNC(BUSDATE), PAY_AMT, 'Manual'
    FROM ERADA.FPAMENT_INFO_MICRO
    WHERE DEBT_RECORD_CODE IS NOT NULL
    UNION ALL
    SELECT DEBT_RECORD_CODE, TRUNC(BUSDATE), BLKAMT, 'Unblock'
    FROM ERADA.FCAM_UNBLK_LOG
),

trx_num AS (
    SELECT t.*,
           ROW_NUMBER() OVER (PARTITION BY DEBT_RECORD_CODE ORDER BY TRX_DATE, SRC, AMT) AS TRX_ID
    FROM trx_loan t
    WHERE NVL(AMT, 0) > 0
      AND DEBT_RECORD_CODE IS NOT NULL
),

trx_seq AS (
    SELECT t.*,
           SUM(AMT) OVER (PARTITION BY DEBT_RECORD_CODE ORDER BY TRX_ID ROWS UNBOUNDED PRECEDING)       AS T_END,
           SUM(AMT) OVER (PARTITION BY DEBT_RECORD_CODE ORDER BY TRX_ID ROWS UNBOUNDED PRECEDING) - AMT AS T_START
    FROM trx_num t
),

/* 2) Manual من غير رقم قرض */
manual_null AS (
    SELECT ROWIDTOCHAR(ROWID) AS PAY_ID, CUSTNO, TRUNC(BUSDATE) AS TRX_DATE, PAY_AMT AS AMT
    FROM ERADA.FPAMENT_INFO_MICRO
    WHERE DEBT_RECORD_CODE IS NULL
      AND NVL(PAY_AMT, 0) > 0
),

manual_seq AS (
    SELECT m.*,
           SUM(AMT) OVER (PARTITION BY CUSTNO ORDER BY TRX_DATE, AMT, PAY_ID ROWS UNBOUNDED PRECEDING)       AS T_END,
           SUM(AMT) OVER (PARTITION BY CUSTNO ORDER BY TRX_DATE, AMT, PAY_ID ROWS UNBOUNDED PRECEDING) - AMT AS T_START
    FROM manual_null m
),

/* 3) الغرامات */
pen AS (
    SELECT DEBT_RECORD_CODE,
           TRUNC(PENALTY_DATE)                                          AS PENALTY_DATE,
           SUM(CASE WHEN FLAG = 0  THEN NVL(PENALTY_AMT,0) ELSE 0 END)  AS PENALTY_DUE,
           SUM(CASE WHEN FLAG = 99 THEN NVL(PENALTY_AMT,0) ELSE 0 END)  AS PENALTY_WAIVED,
           SUM(NVL(PENALTY_SET_AMT,0))                                  AS PENALTY_PAID,
           MAX(CASE WHEN NVL(PENALTY_SET_AMT,0) > 0 THEN TRUNC(SETL_DATE) END) AS PENALTY_SETL_DATE
    FROM ERADA.FDEBTS_PENALTY_DAILY_MICRO
    GROUP BY DEBT_RECORD_CODE, TRUNC(PENALTY_DATE)
),

pen_setl AS (
    SELECT DEBT_RECORD_CODE,
           TRUNC(PENALTY_DATE)   AS PENALTY_DATE,
           TRUNC(SETL_DATE)      AS SETL_DATE,
           SUM(PENALTY_SET_AMT)  AS AMT
    FROM ERADA.FDEBTS_PENALTY_DAILY_MICRO
    WHERE NVL(PENALTY_SET_AMT,0) > 0
      AND SETL_DATE IS NOT NULL
    GROUP BY DEBT_RECORD_CODE, TRUNC(PENALTY_DATE), TRUNC(SETL_DATE)
),

/* 4) الأقساط */
inst AS (
    SELECT
        p.DEBT_RECORD_CODE,
        p.PRIMIUMNO,
        p.PRIMIUM_DATE,
        p.PRIMIUM_VALUE,
        TRUNC(p.SETTLEMENT_DATE)        AS INST_SETTLE_DATE,
        NVL(p.SETTLEMENT_VALUE, 0)      AS SETTLEMENT_VALUE,
        NVL(pn.PENALTY_DUE, 0)          AS PENALTY_DUE,
        NVL(pn.PENALTY_WAIVED, 0)       AS PENALTY_WAIVED,
        NVL(pn.PENALTY_PAID, 0)         AS PENALTY_PAID,
        pn.PENALTY_SETL_DATE
    FROM ERADA.FDEBTS_PRIMIUM_MICRO p
    LEFT JOIN pen pn
        ON  pn.DEBT_RECORD_CODE = p.DEBT_RECORD_CODE
        AND pn.PENALTY_DATE     = TRUNC(p.PRIMIUM_DATE)
),

/* آخر قسط في كل قرض (للفلوس الزيادة عن كل الأقساط) */
loan_last_inst AS (
    SELECT DEBT_RECORD_CODE, MAX(PRIMIUMNO) AS PRIMIUMNO
    FROM inst
    GROUP BY DEBT_RECORD_CODE
),

/* 5) التسويات كأحداث */
settle_events AS (
    SELECT DEBT_RECORD_CODE, PRIMIUMNO, TRUNC(PRIMIUM_DATE) AS DUE,
           'INST' AS STYPE, TRUNC(SETTLEMENT_DATE) AS SET_DATE, SETTLEMENT_VALUE AS AMT
    FROM ERADA.FDEBTS_PRIMIUM_MICRO
    WHERE NVL(SETTLEMENT_VALUE,0) > 0
      AND SETTLEMENT_DATE IS NOT NULL
    UNION ALL
    SELECT ps.DEBT_RECORD_CODE, p.PRIMIUMNO, ps.PENALTY_DATE,
           'PEN', ps.SETL_DATE, ps.AMT
    FROM pen_setl ps
    JOIN ERADA.FDEBTS_PRIMIUM_MICRO p
        ON  p.DEBT_RECORD_CODE    = ps.DEBT_RECORD_CODE
        AND TRUNC(p.PRIMIUM_DATE) = ps.PENALTY_DATE
),

settle_seq AS (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY DEBT_RECORD_CODE
                              ORDER BY SET_DATE, DUE, CASE STYPE WHEN 'PEN' THEN 0 ELSE 1 END, PRIMIUMNO) AS EV_NO,
           SUM(AMT) OVER (PARTITION BY DEBT_RECORD_CODE
                          ORDER BY SET_DATE, DUE, CASE STYPE WHEN 'PEN' THEN 0 ELSE 1 END, PRIMIUMNO
                          ROWS UNBOUNDED PRECEDING)       AS S_END,
           SUM(AMT) OVER (PARTITION BY DEBT_RECORD_CODE
                          ORDER BY SET_DATE, DUE, CASE STYPE WHEN 'PEN' THEN 0 ELSE 1 END, PRIMIUMNO
                          ROWS UNBOUNDED PRECEDING) - AMT AS S_START
    FROM settle_events s
),

/* =====================================================================================
   المرحلة 1-أ: فلوس ليها رقم قرض ← تسويات القرض
   ===================================================================================== */
alloc1 AS (
    SELECT s.DEBT_RECORD_CODE, s.EV_NO, s.PRIMIUMNO, s.SET_DATE,
           t.TRX_ID, t.TRX_DATE, t.SRC,
           LEAST(t.T_END, s.S_END) - GREATEST(t.T_START, s.S_START) AS ALLOC_AMT
    FROM settle_seq s
    JOIN trx_seq t
        ON  t.DEBT_RECORD_CODE = s.DEBT_RECORD_CODE
        AND t.T_START < s.S_END
        AND t.T_END   > s.S_START
),

/* المرحلة 1-ب: Manual من غير رقم قرض ← التسويات الناقصة في كل قروض العميل */
ev_left AS (
    SELECT s.DEBT_RECORD_CODE, s.EV_NO, s.PRIMIUMNO, s.STYPE, s.SET_DATE, s.DUE, lc.CUSTNO,
           s.AMT - NVL(f.FUNDED, 0) AS LEFT_AMT
    FROM settle_seq s
    JOIN loan_cust lc
        ON lc.DEBT_RECORD_CODE = s.DEBT_RECORD_CODE
    LEFT JOIN (
        SELECT DEBT_RECORD_CODE, EV_NO, SUM(ALLOC_AMT) AS FUNDED
        FROM alloc1
        GROUP BY DEBT_RECORD_CODE, EV_NO
    ) f
        ON f.DEBT_RECORD_CODE = s.DEBT_RECORD_CODE AND f.EV_NO = s.EV_NO
    WHERE s.AMT - NVL(f.FUNDED, 0) > 0.001
),

ev_left_seq AS (
    SELECT e.*,
           SUM(LEFT_AMT) OVER (PARTITION BY CUSTNO
                               ORDER BY SET_DATE, DUE, CASE STYPE WHEN 'PEN' THEN 0 ELSE 1 END, DEBT_RECORD_CODE, EV_NO
                               ROWS UNBOUNDED PRECEDING)            AS S_END,
           SUM(LEFT_AMT) OVER (PARTITION BY CUSTNO
                               ORDER BY SET_DATE, DUE, CASE STYPE WHEN 'PEN' THEN 0 ELSE 1 END, DEBT_RECORD_CODE, EV_NO
                               ROWS UNBOUNDED PRECEDING) - LEFT_AMT AS S_START
    FROM ev_left e
),

alloc2 AS (
    SELECT e.DEBT_RECORD_CODE, e.PRIMIUMNO, e.SET_DATE,
           m.PAY_ID, m.TRX_DATE,
           LEAST(m.T_END, e.S_END) - GREATEST(m.T_START, e.S_START) AS ALLOC_AMT
    FROM ev_left_seq e
    JOIN manual_seq m
        ON  m.CUSTNO  = e.CUSTNO
        AND m.T_START < e.S_END
        AND m.T_END   > e.S_START
),

trx_used AS (
    SELECT DEBT_RECORD_CODE, TRX_ID, SUM(ALLOC_AMT) AS USED_AMT
    FROM alloc1
    GROUP BY DEBT_RECORD_CODE, TRX_ID
),

manual_used AS (
    SELECT PAY_ID, SUM(ALLOC_AMT) AS USED_AMT
    FROM alloc2
    GROUP BY PAY_ID
),

/* =====================================================================================
   المرحلة 2: الباقي ← الأقساط اللي لسه فاضل عليها حاجة (بترتيب الاستحقاق)
   ===================================================================================== */
open_due AS (
    SELECT i.DEBT_RECORD_CODE, i.PRIMIUMNO, TRUNC(i.PRIMIUM_DATE) AS DUE, lc.CUSTNO,
           (NVL(i.PRIMIUM_VALUE,0) + i.PENALTY_DUE) - (i.SETTLEMENT_VALUE + i.PENALTY_PAID) AS OPEN_AMT
    FROM inst i
    JOIN loan_cust lc
        ON lc.DEBT_RECORD_CODE = i.DEBT_RECORD_CODE
    WHERE (NVL(i.PRIMIUM_VALUE,0) + i.PENALTY_DUE) - (i.SETTLEMENT_VALUE + i.PENALTY_PAID) > 0.001
),

/* 2-أ: باقي الفلوس اللي ليها رقم قرض ← أقساط نفس القرض */
trx_left AS (
    SELECT t.DEBT_RECORD_CODE, t.TRX_ID, t.TRX_DATE, t.SRC,
           t.AMT - NVL(u.USED_AMT, 0) AS AMT
    FROM trx_seq t
    LEFT JOIN trx_used u
        ON u.DEBT_RECORD_CODE = t.DEBT_RECORD_CODE AND u.TRX_ID = t.TRX_ID
    WHERE t.AMT - NVL(u.USED_AMT, 0) > 0.001
),

trx_left_seq AS (
    SELECT x.*,
           SUM(AMT) OVER (PARTITION BY DEBT_RECORD_CODE ORDER BY TRX_DATE, TRX_ID ROWS UNBOUNDED PRECEDING)       AS T_END,
           SUM(AMT) OVER (PARTITION BY DEBT_RECORD_CODE ORDER BY TRX_DATE, TRX_ID ROWS UNBOUNDED PRECEDING) - AMT AS T_START
    FROM trx_left x
),

open_due_seq AS (
    SELECT d.*,
           SUM(OPEN_AMT) OVER (PARTITION BY DEBT_RECORD_CODE ORDER BY DUE, PRIMIUMNO ROWS UNBOUNDED PRECEDING)            AS S_END,
           SUM(OPEN_AMT) OVER (PARTITION BY DEBT_RECORD_CODE ORDER BY DUE, PRIMIUMNO ROWS UNBOUNDED PRECEDING) - OPEN_AMT AS S_START
    FROM open_due d
),

alloc3 AS (
    SELECT d.DEBT_RECORD_CODE, d.PRIMIUMNO, x.TRX_ID, x.TRX_DATE, x.SRC,
           LEAST(x.T_END, d.S_END) - GREATEST(x.T_START, d.S_START) AS ALLOC_AMT
    FROM open_due_seq d
    JOIN trx_left_seq x
        ON  x.DEBT_RECORD_CODE = d.DEBT_RECORD_CODE
        AND x.T_START < d.S_END
        AND x.T_END   > d.S_START
),

trx_used3 AS (
    SELECT DEBT_RECORD_CODE, TRX_ID, SUM(ALLOC_AMT) AS USED_AMT
    FROM alloc3
    GROUP BY DEBT_RECORD_CODE, TRX_ID
),

/* 2-ب: باقي Manual من غير رقم قرض ← الأقساط المفتوحة في كل قروض العميل */
manual_left AS (
    SELECT m.PAY_ID, m.CUSTNO, m.TRX_DATE,
           m.AMT - NVL(mu.USED_AMT, 0) AS AMT
    FROM manual_seq m
    LEFT JOIN manual_used mu
        ON mu.PAY_ID = m.PAY_ID
    WHERE m.AMT - NVL(mu.USED_AMT, 0) > 0.001
),

manual_left_seq AS (
    SELECT m.*,
           SUM(AMT) OVER (PARTITION BY CUSTNO ORDER BY TRX_DATE, PAY_ID ROWS UNBOUNDED PRECEDING)       AS T_END,
           SUM(AMT) OVER (PARTITION BY CUSTNO ORDER BY TRX_DATE, PAY_ID ROWS UNBOUNDED PRECEDING) - AMT AS T_START
    FROM manual_left m
),

open_due_left AS (
    SELECT od.DEBT_RECORD_CODE, od.PRIMIUMNO, od.DUE, od.CUSTNO,
           od.OPEN_AMT - NVL(a.USED_AMT, 0) AS OPEN_AMT
    FROM open_due od
    LEFT JOIN (
        SELECT DEBT_RECORD_CODE, PRIMIUMNO, SUM(ALLOC_AMT) AS USED_AMT
        FROM alloc3
        GROUP BY DEBT_RECORD_CODE, PRIMIUMNO
    ) a
        ON a.DEBT_RECORD_CODE = od.DEBT_RECORD_CODE AND a.PRIMIUMNO = od.PRIMIUMNO
    WHERE od.OPEN_AMT - NVL(a.USED_AMT, 0) > 0.001
),

open_due_left_seq AS (
    SELECT d.*,
           SUM(OPEN_AMT) OVER (PARTITION BY CUSTNO ORDER BY DUE, DEBT_RECORD_CODE, PRIMIUMNO ROWS UNBOUNDED PRECEDING)            AS S_END,
           SUM(OPEN_AMT) OVER (PARTITION BY CUSTNO ORDER BY DUE, DEBT_RECORD_CODE, PRIMIUMNO ROWS UNBOUNDED PRECEDING) - OPEN_AMT AS S_START
    FROM open_due_left d
),

alloc4 AS (
    SELECT d.DEBT_RECORD_CODE, d.PRIMIUMNO, m.PAY_ID, m.TRX_DATE,
           LEAST(m.T_END, d.S_END) - GREATEST(m.T_START, d.S_START) AS ALLOC_AMT
    FROM open_due_left_seq d
    JOIN manual_left_seq m
        ON  m.CUSTNO  = d.CUSTNO
        AND m.T_START < d.S_END
        AND m.T_END   > d.S_START
),

manual_used4 AS (
    SELECT PAY_ID, SUM(ALLOC_AMT) AS USED_AMT
    FROM alloc4
    GROUP BY PAY_ID
),

/* =====================================================================================
   المرحلة 3: الزيادة عن كل الأقساط ← آخر قسط في القرض
   ===================================================================================== */
cust_main_loan AS (
    SELECT CUSTNO, DEBT_RECORD_CODE
    FROM (
        SELECT li.CUSTNO, li.DEBT_RECORD_CODE,
               ROW_NUMBER() OVER (PARTITION BY li.CUSTNO
                                  ORDER BY CASE WHEN li.LOAN_FLAG = 9 THEN 0 ELSE 1 END,
                                           ls.FIRST_DUE DESC NULLS LAST) AS RN
        FROM loan_info li
        JOIN loan_last_inst ll
            ON ll.DEBT_RECORD_CODE = li.DEBT_RECORD_CODE
        LEFT JOIN loan_span ls
            ON ls.DEBT_RECORD_CODE = li.DEBT_RECORD_CODE
        WHERE li.LOAN_FLAG IN (9, 50)
    )
    WHERE RN = 1
),

excess_alloc AS (
    SELECT ll.DEBT_RECORD_CODE, ll.PRIMIUMNO, x.TRX_DATE, x.SRC,
           'Original' AS FILL_METHOD, 'L' || TO_CHAR(x.TRX_ID) AS TRX_KEY,
           x.AMT - NVL(u3.USED_AMT, 0) AS ALLOC_AMT
    FROM trx_left x
    LEFT JOIN trx_used3 u3
        ON u3.DEBT_RECORD_CODE = x.DEBT_RECORD_CODE AND u3.TRX_ID = x.TRX_ID
    JOIN loan_last_inst ll
        ON ll.DEBT_RECORD_CODE = x.DEBT_RECORD_CODE
    WHERE x.AMT - NVL(u3.USED_AMT, 0) > 0.001
    UNION ALL
    SELECT ll.DEBT_RECORD_CODE, ll.PRIMIUMNO, m.TRX_DATE, 'Manual',
           'By customer', 'M' || m.PAY_ID,
           m.AMT - NVL(u4.USED_AMT, 0)
    FROM manual_left m
    LEFT JOIN manual_used4 u4
        ON u4.PAY_ID = m.PAY_ID
    JOIN cust_main_loan cm
        ON cm.CUSTNO = m.CUSTNO
    JOIN loan_last_inst ll
        ON ll.DEBT_RECORD_CODE = cm.DEBT_RECORD_CODE
    WHERE m.AMT - NVL(u4.USED_AMT, 0) > 0.001
),

/* كل التوزيع مع بعض
   KIND: SET = موّل تسوية / PRE = راح لقسط مفتوح / EXC = زيادة عن كل الأقساط */
alloc_all AS (
    SELECT DEBT_RECORD_CODE, PRIMIUMNO, SET_DATE, TRX_DATE, SRC,
           'Original' AS FILL_METHOD, 'L' || TO_CHAR(TRX_ID) AS TRX_KEY, 'SET' AS KIND, ALLOC_AMT
    FROM alloc1
    UNION ALL
    SELECT DEBT_RECORD_CODE, PRIMIUMNO, SET_DATE, TRX_DATE, 'Manual',
           'By customer', 'M' || PAY_ID, 'SET', ALLOC_AMT
    FROM alloc2
    UNION ALL
    SELECT DEBT_RECORD_CODE, PRIMIUMNO, CAST(NULL AS DATE), TRX_DATE, SRC,
           'Original', 'L' || TO_CHAR(TRX_ID), 'PRE', ALLOC_AMT
    FROM alloc3
    UNION ALL
    SELECT DEBT_RECORD_CODE, PRIMIUMNO, CAST(NULL AS DATE), TRX_DATE, 'Manual',
           'By customer', 'M' || PAY_ID, 'PRE', ALLOC_AMT
    FROM alloc4
    UNION ALL
    SELECT DEBT_RECORD_CODE, PRIMIUMNO, CAST(NULL AS DATE), TRX_DATE, SRC,
           FILL_METHOD, TRX_KEY, 'EXC', ALLOC_AMT
    FROM excess_alloc
),

inst_alloc AS (
    SELECT DEBT_RECORD_CODE, PRIMIUMNO,
           SUM(ALLOC_AMT)                                                          AS TRX_TOTAL,
           SUM(CASE WHEN KIND = 'SET' THEN ALLOC_AMT ELSE 0 END)                   AS FUNDED_SET,
           SUM(CASE WHEN KIND = 'PRE' THEN ALLOC_AMT ELSE 0 END)                   AS PREPAID,
           SUM(CASE WHEN KIND = 'EXC' THEN ALLOC_AMT ELSE 0 END)                   AS EXCESS,
           SUM(CASE WHEN SRC = 'Elec'    THEN ALLOC_AMT ELSE 0 END)                AS ELEC_AMT,
           SUM(CASE WHEN SRC = 'Manual'  THEN ALLOC_AMT ELSE 0 END)                AS MANUAL_AMT,
           SUM(CASE WHEN SRC = 'Unblock' THEN ALLOC_AMT ELSE 0 END)                AS UNBLK_AMT,
           SUM(CASE WHEN KIND = 'SET' AND TRX_DATE > SET_DATE THEN ALLOC_AMT ELSE 0 END) AS LATE_FUNDED_AMT,
           MIN(TRX_DATE)                                                           AS FIRST_TRX_DATE,
           MAX(TRX_DATE)                                                           AS LAST_TRX_DATE,
           COUNT(DISTINCT TRX_KEY)                                                 AS TRX_COUNT,
           MAX(CASE WHEN FILL_METHOD <> 'Original' THEN FILL_METHOD END)           AS FILL_METHOD
    FROM alloc_all
    GROUP BY DEBT_RECORD_CODE, PRIMIUMNO
),

/* =====================================================================================
   النتيجة النهائية
   ===================================================================================== */
final AS (
    /* ---------- صف لكل قسط ---------- */
    SELECT
        li.CUSTNO,
        i.DEBT_RECORD_CODE,
        li.BRANCH_NAME,
        li.PRODUCT_CODE,
        li.PRODUCT_NAME,
        li.LOAN_FLAG,
        li.LOAN_STATUS,
        i.PRIMIUMNO,
        i.PRIMIUM_DATE                                    AS DUE_DATE,
        i.PRIMIUM_VALUE,
        i.PENALTY_DUE,
        i.PENALTY_WAIVED,
        i.PRIMIUM_VALUE + i.PENALTY_DUE                   AS TOTAL_DUE,
        i.INST_SETTLE_DATE,
        i.SETTLEMENT_VALUE,
        i.PENALTY_SETL_DATE,
        i.PENALTY_PAID,
        i.SETTLEMENT_VALUE + i.PENALTY_PAID               AS TOTAL_SETTLED,
        (i.PRIMIUM_VALUE + i.PENALTY_DUE)
          - (i.SETTLEMENT_VALUE + i.PENALTY_PAID)         AS REMAINING,
        a.FIRST_TRX_DATE,
        a.LAST_TRX_DATE                                   AS FINAL_SETTLE_DATE,
        a.TRX_COUNT,
        a.ELEC_AMT,
        a.MANUAL_AMT,
        a.UNBLK_AMT,
        NVL(a.TRX_TOTAL, 0)                               AS FUNDED_AMT,
        NVL(a.TRX_TOTAL, 0)
          - (i.SETTLEMENT_VALUE + i.PENALTY_PAID)         AS DIFF,
        a.FILL_METHOD,
        CASE
            WHEN TRUNC(i.PRIMIUM_DATE) > TRUNC(SYSDATE)                                  THEN 'Not due yet'
            WHEN i.SETTLEMENT_VALUE + i.PENALTY_PAID = 0 AND NVL(a.TRX_TOTAL, 0) = 0     THEN 'Not settled yet'
            WHEN i.SETTLEMENT_VALUE + i.PENALTY_PAID > 0 AND NVL(a.FUNDED_SET, 0) = 0    THEN 'Settled without transaction'
            WHEN NVL(a.FUNDED_SET, 0) < i.SETTLEMENT_VALUE + i.PENALTY_PAID - 0.001      THEN 'Partially funded'
            WHEN NVL(a.EXCESS, 0)  > 0.001                                               THEN 'Overpaid'
            WHEN NVL(a.PREPAID, 0) > 0.001                                               THEN 'Paid, not settled'
            WHEN NVL(a.LATE_FUNDED_AMT, 0) > 0                                           THEN 'Settled before payment'
            ELSE                                                                              'Matched'
        END                                               AS RECON_STATUS,
        TRUNC(i.PRIMIUM_DATE)                             AS SORT_DATE
    FROM inst i
    LEFT JOIN inst_alloc a
        ON a.DEBT_RECORD_CODE = i.DEBT_RECORD_CODE AND a.PRIMIUMNO = i.PRIMIUMNO
    LEFT JOIN loan_info li
        ON li.DEBT_RECORD_CODE = i.DEBT_RECORD_CODE

    UNION ALL

    /* ---------- فلوس على قرض مالوش جدول أقساط ---------- */
    SELECT
        li.CUSTNO,
        x.DEBT_RECORD_CODE,
        li.BRANCH_NAME,
        li.PRODUCT_CODE,
        li.PRODUCT_NAME,
        li.LOAN_FLAG,
        li.LOAN_STATUS,
        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        x.TRX_DATE,
        x.TRX_DATE,
        1,
        CASE WHEN x.SRC = 'Elec'    THEN x.AMT ELSE 0 END,
        CASE WHEN x.SRC = 'Manual'  THEN x.AMT ELSE 0 END,
        CASE WHEN x.SRC = 'Unblock' THEN x.AMT ELSE 0 END,
        x.AMT,
        x.AMT,
        NULL,
        'Transaction - loan has no installments',
        x.TRX_DATE
    FROM trx_left x
    LEFT JOIN loan_last_inst ll
        ON ll.DEBT_RECORD_CODE = x.DEBT_RECORD_CODE
    LEFT JOIN loan_info li
        ON li.DEBT_RECORD_CODE = x.DEBT_RECORD_CODE
    WHERE ll.DEBT_RECORD_CODE IS NULL
)

   ===================================================================================== */
SELECT f.*
FROM final f
WHERE f.LOAN_FLAG IN (9, 50)
  AND NOT EXISTS (
        SELECT 1 FROM early_paid ep
        WHERE ep.DEBT_RECORD_CODE = f.DEBT_RECORD_CODE
      )
ORDER BY f.CUSTNO, f.DEBT_RECORD_CODE, f.SORT_DATE, f.PRIMIUMNO;