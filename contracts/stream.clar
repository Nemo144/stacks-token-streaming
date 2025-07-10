
;; title: stream
;; version:
;; summary: Token-streaming protocol
;; description: Establishing a continuous payment stream between two parties 

;; traits
;;

;; token definitions
;;

;; constants
;;error codes
(define-constant ERR_UNAUTHORIZED (err u0)) ;;tries to withdraw from a stream where there are not the recipient 
(define-constant ERR_INVALID_SIGNATURE (err u1)) ;;provides an invalid signature while updating the stream 
(define-constant ERR_STREAM_STILL_ACTIVE (err u2)) ;;tries to withdraw tokens not yet withdrawn by the recipient before the final block has been hit
(define-constant ERR_INVALID_STREAM_ID (err u3)) ;;tries to refuel token without proper stream id 

;; data vars
;;latest stream id to keep track of the latest stream ID initially set to 0
(define-data-var latest-stream-id uint u0)

;; data maps
;;creating a stream requires 
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
      ;;temporary variable = current-stream-id which is just the value of our latest-stream-id data variable
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
          ;;use the stream-id to fetch the actual stream tuple from the mapping
          (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
          )
          ;;assert and make sure the contract caller is the sender of the stream
          (asserts! (is-eq contract-caller (get sender stream)) ERR_UNAUTHORIZED)

          ;;transfer stx tokens from the sender to the contract principal's address
          (try! (stx-transfer? amount contract-caller (as-contract tx-sender)))

          ;;update the mapping for the given stream-id to have an updated balance
          ;;by merging the existing stream tuple with a new tuple that has an updated balance
          (map-set streams stream-id 
          (merge stream {balance: (+ (get balance stream) amount)})
          )

          ;;return ok with the amount of token that was refueled
          (ok amount)
          )
        )

        ;;withdraw received tokens
        (define-public (withdraw 
          (stream-id uint)
          )
          (let (
            ;;get a refrence on the actual stream based on the stream-id
            (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
            ;;how much balance from this stream is pending for the contract-caller
            (balance (balance-of stream-id contract-caller))
          )
          ;;assert that the contract-caller is the stream recipient otherwise throw the unathourized error
          (asserts! (is-eq contract-caller (get recipient stream)) ERR_UNAUTHORIZED)
          ;;update mapping to increase the withdrawn-balance based on whatever balance is available for the recipient to withdraw
          (map-set streams stream-id 
            (merge stream {withdrawn-balance: (+ (get withdrawn-balance stream) balance)})
            )
            ;;transfer balance amount of stx token from the contract to the stream recipient
            (try! (as-contract (stx-transfer? balance tx-sender (get recipient stream))))
            (ok balance)
          )
          )

        ;;withdraw excess locked tokens
        ;;the refund function takes in a stream-id argument that is used to get a reference to the stream tuple from the mapping
        (define-public (refund
            (stream-id uint)
            )
            (let (
              (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID ))
              ;;calculate the balance for the stream sender
              (balance (balance-of stream-id (get sender stream)))
            )
            ;;ensure the contract-caller is the stream sender
            (asserts! (is-eq contract-caller (get sender stream)) ERR_UNAUTHORIZED)
            ;;ensure the stream is past the stop block
            (asserts! (< (get stop-block (get timeframe stream)) block-height) ERR_STREAM_STILL_ACTIVE)
            ;;update our mapping to reduce the overall balance of the stream to be the previous balance minus whatever amount is being withdrawn
            (map-set streams stream-id  (merge stream {
              balance: (- (get balance stream) balance),
            }
            ))
            ;;token transfer from our contract to the stream sender
            (try! (as-contract (stx-transfer? balance tx-sender (get sender stream))))
            (ok balance)
            )
            )

      ;;update stream configuration
      (define-public (update-details 
          (stream-id uint)
          (payment-per-block uint)
          (timeframe (tuple (start-block uint) (stop-block uint)))
          (signer principal)
          (signature (buff 65))
          )
          (let (
            (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
          )
            (asserts! (validate-signature (hash-stream stream-id payment-per-block timeframe) signature signer) ERR_INVALID_SIGNATURE)
            (asserts! 
              (or 
                (and (is-eq (get sender stream) contract-caller) (is-eq (get recipient stream) signer))
                 (and (is-eq (get sender stream) signer) (is-eq (get recipient stream) contract-caller))
                 )
                 ERR_UNAUTHORIZED
                 )
                 (map-set streams stream-id (merge stream {
                   payment-per-block: payment-per-block,
                   timeframe: timeframe
                 }))
                 (ok true)
          )
          )

;; read only functions
;;to calculate how many blocks have passed since the starting block of a stream
(define-read-only (calculate-block-delta
   (timeframe (tuple (start-block uint) (stop-block uint)))
   )
   (let (
    (start-block (get start-block timeframe))
    (stop-block (get stop-block timeframe))

    (delta
     (if (<= block-height start-block)
       ;;then stream is not active yet and 0 is returned
       u0
       ;;else
       (if (< block-height stop-block)
        ;;then the stream is active and not ended yet so return  block-height - start-block
        (- block-height start-block)
         ;;else the stream is now over and the full range i.e stop-block - start-block is returned
        (- stop-block start-block)
       )
     )
     )
    )
    delta
   )
   )

   ;;to check the withdrawable balance for a party involved in a stream i.e either the sender or the recipient
   (define-read-only (balance-of
      (stream-id uint)
      (who principal)
      ) 
      (let (
      ;;getting the refrence of the actual stream based on the id from the mapping 
        (stream (unwrap! (map-get? streams stream-id) u0))
      ;;calculate the current block delta
        (block-delta (calculate-block-delta (get timeframe stream)))
      ;;calculate how much tokens are withdrawable from the recipient
        (recipient-balance (* block-delta (get payment-per-block stream)))
      )
      ;;checking for the balance of the recipient
        (if (is-eq who (get recipient stream)) 
        (- recipient-balance (get withdrawn-balance stream)) 
        ;;checking for the balance of the sender
        (if (is-eq who (get sender stream)) 
          (- (get balance stream) recipient-balance)
          u0
      )
      )
      )
      )

      ;;get hash of streams
      (define-read-only (hash-stream 
           (stream-id uint)
           (new-payment-per-block uint)
           (new-timeframe (tuple (start-block uint) (stop-block uint)))
           )
           (let (
           ;;getting the refrence of the actual stream based on the id from the mapping 
            (stream (unwrap! (map-get? streams stream-id) (sha256 0)))
           ;;convert the stream tuple into a buffer using the "to-consensus-buff",Convert the new-payment-per-block to a Buffer and concatnate
           ;;the three buffers to produce a temporary variable named msg
            (msg (concat (concat (unwrap-panic (to-consensus-buff? stream)) (unwrap-panic (to-consensus-buff? new-payment-per-block))) 
            (unwrap-panic (to-consensus-buff? new-timeframe))))
           )
           ;;Do a SHA-256 hash over msg
           (sha256 msg)
           )
      )

      ;;signature verification
      (define-read-only (validate-signature (hash (buff 32)) (signature (buff 65))
      (signer principal))
          (is-eq 
            (principal-of? (unwrap! (secp256k1-recover? hash signature) false)) 
            (ok signer)
            )
      )

;; private functions
;;

