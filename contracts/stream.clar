
;; title: stream
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;error codes
(define-constant ERR_UNAUTHORIZED (err u0))
(define-constant ERR_INVALID_SIGNATURE (err u1))
(define-constant ERR_STREAM_STILL_ACTIVE (err u2))
(define-constant ERR_INVALID_STREAM_ID (err u3))

;; data vars
;;latest stream id to keep track of the latest streams
(define-data-var latest-stream-id uint u0)

;; data maps
;;streams mapping
(define-map streams 
  uint ;;stream id
  { sender: principal,
    recipient: principal,
    balance: uint,
    withdrawn-balance: uint,
    payment-per-block: uint,
    timeframe: (tuple (start-block uint) (stop-block uint)) })

;; public functions
;;function for the new stream
(define-public (stream-to
    (recipient principal)
    (initial-balance uint)
    (timeframe (tuple (start-block uint) (stop-block uint)))
    (payment-per-block uint)
    )
    (let (
      (stream {
        sender: contract-caller,
        recipient: recipient,
        balance: initial-balance,
        withdrawn-balance: u0,
        payment-per-block: payment-per-block,
        timeframe: timeframe
      })
      (current-stream-id (var-get latest-stream-id))
      ) 
      ;;the 'stx-transfer' fnc takes in (amount sender recipient)
      ;;replacing the 'recipient' to "as-contract tx-sender" since as-contract switches the tx-sender variable to the contract principal
      ;;i.e doing this gives us the contract address itself
      (try! (stx-transfer? initial-balance contract-caller (as-contract tx-sender)))
      (map-set streams current-stream-id stream)
      (var-set latest-stream-id (+ current-stream-id u1))
      (ok current-stream-id)
      )) 

      ;;function to refuel the tokens for a stream already created 
      (define-public (refuel 
        (stream-id uint)
        (amount uint)
        )
        (let (
          (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
          )
          (asserts! (is-eq contract-caller (get sender stream)) ERR_UNAUTHORIZED)
          (try! (stx-transfer? amount contract-caller (as-contract tx-sender)))
          (map-set streams stream-id 
          (merge stream {balance: (+ (get balance stream) amount)})
          )
          (ok amount)
          )
        )

;; read only functions
;;

;; private functions
;;

