;; StableSwap: A decentralized stable swap protocol that generates rewards for sBTC holders

;; Define SIP-010 fungible token trait
(define-trait ft-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-balance (principal) (response uint uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 32) uint))
    (get-decimals () (response uint uint))
    (get-total-supply () (response uint uint))
    (get-token-uri () (response (optional (string-utf8 256)) uint))
  )
)

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_INSUFFICIENT_LIQUIDITY (err u102))
(define-constant ERR_SLIPPAGE_EXCEEDED (err u103))
(define-constant ERR_INVALID_AMOUNT (err u104))
(define-constant ERR_POOL_IMBALANCED (err u105))
(define-constant ERR_ZERO_LIQUIDITY (err u106))
(define-constant ERR_NOT_AUTHORIZED (err u107))
(define-constant ERR_REWARD_CLAIM_FAILED (err u108))
(define-constant ERR_LIST_FULL (err u109))
(define-constant ERR_INVALID_POOL_ID (err u110))
(define-constant ERR_INVALID_TOKEN (err u111))
(define-constant ERR_INVALID_AMPLIFICATION (err u112))
(define-constant ERR_INVALID_PRINCIPAL (err u113))

;; Fee settings - 0.3% swap fee, 70% to LPs, 30% to sBTC holders
(define-constant FEE_DENOMINATOR u1000)
(define-constant SWAP_FEE_BPS u3) ;; 0.3%
(define-constant LP_FEE_PERCENT u70) 
(define-constant SBTC_REWARD_PERCENT u30)

;; Token definitions
(define-fungible-token stableswap-token)
(define-fungible-token lp-token)

;; Data maps
(define-map pools
  { pool-id: uint }
  {
    token-x: principal,
    token-y: principal,
    balance-x: uint,
    balance-y: uint,
    amplification: uint,
    total-liquidity: uint
  }
)

(define-map user-liquidity
  { user: principal, pool-id: uint }
  { amount: uint }
)

(define-map sbtc-holders
  { holder: principal }
  { balance: uint, last-claim-height: uint }
)

(define-map accumulated-rewards
  { pool-id: uint }
  { amount: uint }
)

(define-map all-sbtc-holders-map
  { holder: principal }
  { active: bool }
)

(define-data-var sbtc-holders-list (list 500 principal) (list))

;; Mathematical helpers simplified
(define-read-only (sqrt (n uint))
  (if (is-eq n u0)
    u0
    (let ((x0 (/ (+ n u1) u2)))
      (/ (+ x0 (/ n x0)) u2)
    )
  )
)

(define-read-only (compute-d (x uint) (y uint) (a uint))
  (let ((sum (+ x y)))
    (if (is-eq sum u0)
      u0
      (let
        (
          (d sum)
          (ann (* a u2))
          (d-squared (* d d))
          (term1 (/ (* ann (* x y)) (* d-squared d)))
          (term2 (/ ann u2))
        )
        (/ (* d (+ u1 (- term1 term2))) u1)
      )
    )
  )
)

(define-read-only (compute-y (x uint) (d uint) (amp uint))
  (let
    (
      (ann (* amp u2))
      (c (/ (* d (* d d)) (* u4 ann x)))
      (b (+ x (/ d amp)))
      (discriminant (+ (* b b) (* u4 c)))
    )
    (/ (- (sqrt discriminant) b) u2)
  )
)

;; Swap calculation functions
(define-read-only (calculate-fee (dx uint))
  (* dx SWAP_FEE_BPS)
)

(define-read-only (compute-swap-amount (x uint) (y uint) (dx uint) (amp uint))
  (let
    (
      (fee-amount (calculate-fee dx))
      (dx-with-fee (- dx fee-amount))
      (x-new (+ x dx-with-fee))
      (d (compute-d x y amp))
      (y-new (compute-y x-new d amp))
      (dy (- y y-new))
    )
    { dx: dx, dy: dy, fee: fee-amount }
  )
)

;; Input validation functions
(define-private (is-valid-pool-id (pool-id uint))
  (is-some (map-get? pools { pool-id: pool-id }))
)

(define-private (is-valid-amplification (amp uint))
  (and (> amp u0) (< amp u10000))
)

;; Validate principal is not zero address
(define-private (is-valid-principal (principal-to-check principal))
  (not (is-eq principal-to-check 'SP000000000000000000002Q6VF78)))

;; Pool management functions
(define-public (create-pool 
    (token-x principal)
    (token-y principal)
    (amplification uint)
    (pool-id uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    ;; Validate inputs
    (asserts! (not (is-valid-pool-id pool-id)) ERR_INVALID_POOL_ID)
    (asserts! (is-valid-principal token-x) ERR_INVALID_PRINCIPAL)
    (asserts! (is-valid-principal token-y) ERR_INVALID_PRINCIPAL)
    (asserts! (is-valid-amplification amplification) ERR_INVALID_AMPLIFICATION)
    
    (map-set pools
      { pool-id: pool-id }
      {
        token-x: token-x,
        token-y: token-y,
        balance-x: u0,
        balance-y: u0,
        amplification: amplification,
        total-liquidity: u0
      }
    )
    (ok true)
  )
)

(define-read-only (get-pool (pool-id uint))
  (map-get? pools { pool-id: pool-id })
)

;; User-facing swap
(define-public (swap 
    (pool-id uint) 
    (token-x <ft-trait>)
    (token-y <ft-trait>)
    (amount-in uint)
    (min-amount-out uint))
  (let
    (
      ;; Validate pool-id
      (valid-pool (asserts! (is-valid-pool-id pool-id) ERR_INVALID_POOL_ID))
      (pool (unwrap! (get-pool pool-id) ERR_INVALID_AMOUNT))
      (token-x-principal (get token-x pool))
      (token-y-principal (get token-y pool))
      (balance-x (get balance-x pool))
      (balance-y (get balance-y pool))
      (amp (get amplification pool))
      ;; Determine direction of swap based on tx-sender's intent
      (is-x-to-y true)  ;; Default direction X to Y
      (x balance-x)
      (y balance-y)
      (swap-result (compute-swap-amount x y amount-in amp))
      (amount-out (get dy swap-result))
      (fee (get fee swap-result))
      (lp-fee (/ (* fee LP_FEE_PERCENT) u100))
      (sbtc-reward (/ (* fee SBTC_REWARD_PERCENT) u100))
    )
    ;; Check conditions
    (asserts! (> amount-in u0) ERR_INVALID_AMOUNT)
    (asserts! (>= amount-out min-amount-out) ERR_SLIPPAGE_EXCEEDED)
    (asserts! (is-eq (contract-of token-x) token-x-principal) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (contract-of token-y) token-y-principal) ERR_NOT_AUTHORIZED)
    
    ;; Transfer tokens from user
    (unwrap! (contract-call? token-x transfer amount-in tx-sender (as-contract tx-sender) none) ERR_INSUFFICIENT_BALANCE)
    
    ;; Update pool state
    (map-set pools 
      { pool-id: pool-id } 
      (merge pool {
        balance-x: (+ balance-x amount-in),
        balance-y: (- balance-y amount-out)
      })
    )
    
    ;; Update rewards
    (map-set accumulated-rewards
      { pool-id: pool-id }
      { amount: (+ (get amount (default-to { amount: u0 } 
                   (map-get? accumulated-rewards { pool-id: pool-id }))) sbtc-reward) })
    
    ;; Transfer tokens to user
    (unwrap! (as-contract (contract-call? token-y transfer amount-out (as-contract tx-sender) tx-sender none)) 
              ERR_INSUFFICIENT_BALANCE)
    
    (ok { token-out: token-y-principal, amount-out: amount-out })
  )
)

;; Add liquidity
(define-public (add-liquidity
    (pool-id uint)
    (token-x <ft-trait>)
    (token-y <ft-trait>)
    (amount-x uint)
    (amount-y uint)
    (min-lp-tokens uint))
  (let
    (
      ;; Validate pool-id
      (valid-pool (asserts! (is-valid-pool-id pool-id) ERR_INVALID_POOL_ID))
      (pool (unwrap! (get-pool pool-id) ERR_INVALID_AMOUNT))
      (token-x-principal (get token-x pool))
      (token-y-principal (get token-y pool))
      (balance-x (get balance-x pool))
      (balance-y (get balance-y pool))
      (total-liquidity (get total-liquidity pool))
      (amp (get amplification pool))
      (d-before (compute-d balance-x balance-y amp))
      (d-after (compute-d (+ balance-x amount-x) (+ balance-y amount-y) amp))
      (lp-tokens-to-mint (if (is-eq total-liquidity u0)
                            (compute-d amount-x amount-y amp)
                            (/ (* total-liquidity (- d-after d-before)) d-before)))
    )
    (asserts! (> amount-x u0) ERR_INVALID_AMOUNT)
    (asserts! (> amount-y u0) ERR_INVALID_AMOUNT)
    (asserts! (>= lp-tokens-to-mint min-lp-tokens) ERR_SLIPPAGE_EXCEEDED)
    (asserts! (is-eq (contract-of token-x) token-x-principal) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (contract-of token-y) token-y-principal) ERR_NOT_AUTHORIZED)
    
    ;; Transfer tokens
    (unwrap! (contract-call? token-x transfer amount-x tx-sender (as-contract tx-sender) none) ERR_INSUFFICIENT_BALANCE)
    (unwrap! (contract-call? token-y transfer amount-y tx-sender (as-contract tx-sender) none) ERR_INSUFFICIENT_BALANCE)
    
    ;; Update state
    (map-set pools { pool-id: pool-id }
      (merge pool {
        balance-x: (+ balance-x amount-x),
        balance-y: (+ balance-y amount-y),
        total-liquidity: (+ total-liquidity lp-tokens-to-mint)
      })
    )
    
    (map-set user-liquidity
      { user: tx-sender, pool-id: pool-id }
      { amount: (+ (get amount (default-to { amount: u0 } 
                   (map-get? user-liquidity { user: tx-sender, pool-id: pool-id }))) lp-tokens-to-mint) }
    )
    
    (unwrap! (ft-mint? lp-token lp-tokens-to-mint tx-sender) ERR_INSUFFICIENT_BALANCE)
    
    (ok { lp-tokens: lp-tokens-to-mint })
  )
)

;; Remove liquidity function
(define-public (remove-liquidity
    (pool-id uint)
    (token-x <ft-trait>)
    (token-y <ft-trait>)
    (lp-amount uint)
    (min-amount-x uint)
    (min-amount-y uint))
  (let
    (
      ;; Validate pool-id
      (valid-pool (asserts! (is-valid-pool-id pool-id) ERR_INVALID_POOL_ID))
      (pool (unwrap! (get-pool pool-id) ERR_INVALID_AMOUNT))
      (token-x-principal (get token-x pool))
      (token-y-principal (get token-y pool))
      (balance-x (get balance-x pool))
      (balance-y (get balance-y pool))
      (total-liquidity (get total-liquidity pool))
      (user-lp (unwrap! (map-get? user-liquidity { user: tx-sender, pool-id: pool-id }) ERR_INSUFFICIENT_BALANCE))
      (amount-x-to-return (/ (* balance-x lp-amount) total-liquidity))
      (amount-y-to-return (/ (* balance-y lp-amount) total-liquidity))
    )
    (asserts! (> lp-amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (get amount user-lp) lp-amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (>= amount-x-to-return min-amount-x) ERR_SLIPPAGE_EXCEEDED)
    (asserts! (>= amount-y-to-return min-amount-y) ERR_SLIPPAGE_EXCEEDED)
    (asserts! (is-eq (contract-of token-x) token-x-principal) ERR_NOT_AUTHORIZED)
    (asserts! (is-eq (contract-of token-y) token-y-principal) ERR_NOT_AUTHORIZED)
    
    ;; Burn LP tokens
    (unwrap! (ft-burn? lp-token lp-amount tx-sender) ERR_INSUFFICIENT_BALANCE)
    
    ;; Update pool
    (map-set pools 
      { pool-id: pool-id }
      (merge pool {
        balance-x: (- balance-x amount-x-to-return),
        balance-y: (- balance-y amount-y-to-return),
        total-liquidity: (- total-liquidity lp-amount)
      })
    )
    
    ;; Update user liquidity
    (map-set user-liquidity
      { user: tx-sender, pool-id: pool-id }
      { amount: (- (get amount user-lp) lp-amount) }
    )
    
    ;; Return tokens
    (unwrap! (as-contract (contract-call? token-x transfer amount-x-to-return (as-contract tx-sender) tx-sender none)) ERR_INSUFFICIENT_BALANCE)
    (unwrap! (as-contract (contract-call? token-y transfer amount-y-to-return (as-contract tx-sender) tx-sender none)) ERR_INSUFFICIENT_BALANCE)
    
    (ok { amount-x: amount-x-to-return, amount-y: amount-y-to-return })
  )
)

;; Check if holder already exists in the list
(define-read-only (holder-exists (holder principal))
  (default-to { active: false } (map-get? all-sbtc-holders-map { holder: holder }))
)

;; Register sBTC holder
(define-public (register-sbtc-holder (holder principal) (amount uint))
  (let
    (
      (holders-list (var-get sbtc-holders-list))
      (exists (get active (holder-exists holder)))
    )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
    (asserts! (is-valid-principal holder) ERR_INVALID_PRINCIPAL)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    ;; Update holder data
    (map-set sbtc-holders
      { holder: holder }
      { balance: amount, last-claim-height: block-height }
    )
    
    ;; Only add to list if not already in it
    (if (not exists)
      (begin
        ;; Check list capacity
        (asserts! (< (len holders-list) u500) ERR_LIST_FULL)
        
        ;; Update holder tracking
        (map-set all-sbtc-holders-map
          { holder: holder }
          { active: true }
        )
        
        ;; Append to list only if not already there and we have space
        (var-set sbtc-holders-list (unwrap! (as-max-len? (append holders-list holder) u500) ERR_LIST_FULL))
      )
      true
    )
    
    (ok true)
  )
)

;; Helper to get sBTC balance
(define-read-only (get-sbtc-balance (holder principal))
  (get balance (default-to { balance: u0, last-claim-height: u0 } 
               (map-get? sbtc-holders { holder: holder })))
)

;; Claim rewards
(define-public (claim-rewards (pool-id uint) (token-x <ft-trait>))
  (let
    (
      ;; Validate pool-id
      (valid-pool (asserts! (is-valid-pool-id pool-id) ERR_INVALID_POOL_ID))
      (holder tx-sender)
      (holder-info (default-to { balance: u0, last-claim-height: u0 } 
                   (map-get? sbtc-holders { holder: holder })))
      (balance (get balance holder-info))
      (total-sbtc (fold + (map get-sbtc-balance (var-get sbtc-holders-list)) u0))
      (pool-rewards (get amount (default-to { amount: u0 } 
                    (map-get? accumulated-rewards { pool-id: pool-id }))))
      (rewards (if (is-eq total-sbtc u0) u0 (/ (* pool-rewards balance) total-sbtc)))
      (pool (unwrap! (get-pool pool-id) ERR_INVALID_AMOUNT))
      (token-x-principal (get token-x pool))
    )
    (asserts! (> balance u0) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> rewards u0) ERR_REWARD_CLAIM_FAILED)
    (asserts! (is-eq (contract-of token-x) token-x-principal) ERR_NOT_AUTHORIZED)
    
    ;; Update state
    (map-set accumulated-rewards
      { pool-id: pool-id }
      { amount: (- pool-rewards rewards) }
    )
    
    (map-set sbtc-holders
      { holder: holder }
      (merge holder-info { last-claim-height: block-height })
    )
    
    ;; Transfer rewards
    (unwrap! (as-contract (contract-call? token-x transfer rewards 
              (as-contract tx-sender) holder none)) 
              ERR_REWARD_CLAIM_FAILED)
    
    (ok rewards)
  )
)