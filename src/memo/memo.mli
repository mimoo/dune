open! Stdune

(* CR-someday amokhov: The current implementation memoizes all errors, which may
   be inconvenient in rare cases, e.g. if a build action fails due to a spurious
   error, such as running out of memory. Right now, the only way to force such
   actions to be rebuilt is to restart Dune, which clears all memoized errors.
   In future, we would like to provide a way to rerun all actions failed due to
   errors without restarting the build, e.g. via a Dune RPC call. *)

type 'a build

module type Build = sig
  include Monad

  module List : sig
    val map : 'a list -> f:('a -> 'b t) -> 'b list t
  end

  val memo_build : 'a build -> 'a t
end

(* This should eventually be just [Module Build : Build] *)
module Build : sig
  (** The build monad *)

  include Build with type 'a t = 'a build

  val run : 'a t -> 'a Fiber.t

  (** [of_reproducible_fiber fiber] injects a fiber into the build monad. This
      module assumes that the given fiber is "reproducible", i.e. that executing
      it multiple times will always yield the same result.

      It is however up to the user to ensure this property. *)
  val of_reproducible_fiber : 'a Fiber.t -> 'a t

  val return : 'a -> 'a t

  val both : 'a t -> 'b t -> ('a * 'b) t

  (** This uses a sequential implementation. We use the short name to conform
      with the [Applicative] interface. See [all_concurrently] for the version
      with concurrency. *)
  val all : 'a t list -> 'a list t

  val all_concurrently : 'a t list -> 'a list t

  val if_ : bool -> (unit -> unit t) -> unit t

  val sequential_map : 'a list -> f:('a -> 'b t) -> 'b list t

  val sequential_iter : 'a list -> f:('a -> unit t) -> unit t

  val fork_and_join : (unit -> 'a t) -> (unit -> 'b t) -> ('a * 'b) t

  val fork_and_join_unit : (unit -> unit t) -> (unit -> 'a t) -> 'a t

  val parallel_map : 'a list -> f:('a -> 'b t) -> 'b list t

  val parallel_iter : 'a list -> f:('a -> unit t) -> unit t

  val parallel_iter_set :
       (module Set.S with type elt = 'a and type t = 's)
    -> 's
    -> f:('a -> unit t)
    -> unit t

  module Make_map_traversals (Map : Map.S) : sig
    val parallel_iter : 'a Map.t -> f:(Map.key -> 'a -> unit t) -> unit t

    val parallel_map : 'a Map.t -> f:(Map.key -> 'a -> 'b t) -> 'b Map.t t
  end
  [@@inline always]

  (** The bellow functions will eventually disappear and are only exported for
      the transition to the memo monad *)

  val with_error_handler :
    (unit -> 'a t) -> on_error:(Exn_with_backtrace.t -> unit t) -> 'a t

  val map_reduce_errors :
       (module Monoid with type t = 'a)
    -> on_error:(Exn_with_backtrace.t -> 'a t)
    -> (unit -> 'b t)
    -> ('b, 'a) result t

  val collect_errors :
    (unit -> 'a t) -> ('a, Exn_with_backtrace.t list) Result.t t

  val finalize : (unit -> 'a t) -> finally:(unit -> unit t) -> 'a t

  val reraise_all : Exn_with_backtrace.t list -> 'a t

  module Option : sig
    val iter : 'a option -> f:('a -> unit t) -> unit t

    val map : 'a option -> f:('a -> 'b t) -> 'b option t

    val bind : 'a option -> f:('a -> 'b option t) -> 'b option t
  end

  module Result : sig
    val iter : ('a, _) result -> f:('a -> unit t) -> unit t
  end
end

type ('input, 'output) t

(** A stack frame within a computation. *)
module Stack_frame : sig
  type ('input, 'output) memo = ('input, 'output) t

  type t

  val to_dyn : t -> Dyn.t

  val name : t -> string option

  val input : t -> Dyn.t

  (** Checks if the stack frame is a frame of the given memoized function and if
      so, returns [Some i] where [i] is the argument of the function. *)
  val as_instance_of : t -> of_:('input, _) memo -> 'input option
end

module Cycle_error : sig
  type t

  exception E of t

  (** Get the list of stack frames in this cycle. *)
  val get : t -> Stack_frame.t list

  (** Return the stack leading to the node which raised the cycle. *)
  val stack : t -> Stack_frame.t list
end

(** Notify the memoization system that the build system has restarted. This
    removes the values that depend on the [current_run] from the memoization
    cache, and cancels all pending computations. *)
val reset : unit -> unit

(** Notify the memoization system that the build system has restarted but do not
    clear the memoization cache. *)
val restart_current_run : unit -> unit

(** Returns [true] if the user enabled the incremental mode via the environment
    variable [DUNE_WATCHING_MODE_INCREMENTAL], and we should therefore assume
    that the build system tracks all relevant side effects in the [Build] monad. *)
val incremental_mode_enabled : bool

module type Output_simple = sig
  type t

  val to_dyn : t -> Dyn.t
end

module type Output_allow_cutoff = sig
  type t

  val to_dyn : t -> Dyn.t

  val equal : t -> t -> bool
end

(** When we recompute the function and find that its output is the same as what
    we computed before, we can sometimes skip recomputing the values that depend
    on it.

    [Allow_cutoff] specifies how to compare the output values for that purpose.

    Note that currently Dune wipes all memoization caches on every run, so
    cutoff is not effective. *)
module Output : sig
  type 'o t =
    | Simple of (module Output_simple with type t = 'o)
    | Allow_cutoff of (module Output_allow_cutoff with type t = 'o)

  val simple : ?to_dyn:('a -> Dyn.t) -> unit -> 'a t
end

module type Input = sig
  type t

  include Table.Key with type t := t
end

module Visibility : sig
  type 'i t =
    | Hidden
    | Public of 'i Dune_lang.Decoder.t
end

module Store : sig
  module type Input = sig
    type t

    val to_dyn : t -> Dyn.t
  end

  module type S = sig
    type key

    type 'a t

    val create : unit -> _ t

    val clear : _ t -> unit

    val set : 'a t -> key -> 'a -> unit

    val find : 'a t -> key -> 'a option
  end
end

val create_with_store :
     string
  -> store:(module Store.S with type key = 'i)
  -> ?doc:string
  -> input:(module Store.Input with type t = 'i)
  -> visibility:'i Visibility.t
  -> output:'o Output.t
  -> ('i -> 'o Fiber.t)
  -> ('i, 'o) t

(** [create name ~doc ~input ~visibility ~output f] creates a memoized version
    of [f : 'i -> 'o Build.t]. The result of [f] for a given input is cached, so
    that the second time [exec t x] is called, the previous result is re-used if
    possible.

    [exec t x] tracks what calls to other memoized function [f x] performs. When
    the result of such dependent call changes, [exec t x] will automatically
    recompute [f x].

    Running the computation may raise [Memo.Cycle_error.E] if a cycle is
    detected.

    [visibility] determines whether the function is user-facing or internal and
    if it's user-facing then how to parse the values written by the user. *)
val create :
     string
  -> ?doc:string
  -> input:(module Input with type t = 'i)
  -> visibility:'i Visibility.t
  -> output:'o Output.t
  -> ('i -> 'o Build.t)
  -> ('i, 'o) t

val create_hidden :
     string
  -> ?doc:string
  -> input:(module Input with type t = 'i)
  -> ('i -> 'o Build.t)
  -> ('i, 'o) t

(** Execute a memoized function *)
val exec : ('i, 'o) t -> 'i -> 'o Build.t

(** After running a memoization function with a given name and input, it is
    possible to query which dependencies that function used during execution by
    calling [get_deps] with the name and input used during execution.

    Returns [None] if the dependencies were not computed yet. *)
val get_deps : ('i, _) t -> 'i -> (string option * Dyn.t) list option

(** Print the memoized call stack during execution. This is useful for debugging
    purposes. *)
val dump_stack : unit -> unit Fiber.t

val pp_stack : unit -> _ Pp.t Fiber.t

(** Get the memoized call stack during the execution of a memoized function. *)
val get_call_stack : unit -> Stack_frame.t list Build.t

(** Call a memoized function by name *)
val call : string -> Dune_lang.Ast.t -> Dyn.t Build.t

module Run : sig
  (** A single build run. *)
  type t
end

(** Introduces a dependency on the current build run. *)
val current_run : unit -> Run.t Build.t

module Info : sig
  type t =
    { name : string
    ; doc : string option
    }
end

(** Return the list of registered functions *)
val registered_functions : unit -> Info.t list

(** Lookup function's info *)
val function_info : name:string -> Info.t

module Lazy : sig
  type 'a t

  val of_val : 'a -> 'a t

  val create :
       ?cutoff:('a -> 'a -> bool)
    -> ?to_dyn:('a -> Dyn.t)
    -> (unit -> 'a Build.t)
    -> 'a t

  val force : 'a t -> 'a Build.t

  val map : 'a t -> f:('a -> 'b) -> 'b t
end

val lazy_ :
     ?cutoff:('a -> 'a -> bool)
  -> ?to_dyn:('a -> Dyn.t)
  -> (unit -> 'a Build.t)
  -> 'a Lazy.t

module Implicit_output : sig
  type 'o t

  (** [produce] and [produce_opt] are used by effectful functions to produce
      output. *)
  val produce : 'o t -> 'o -> unit Build.t

  val produce_opt : 'o t -> 'o option -> unit Build.t

  (** [collect] and [forbid] take a potentially effectful function (one which
      may produce some implicit output) and turn it into a pure one (with
      explicit output if any). *)
  val collect : 'o t -> (unit -> 'a Build.t) -> ('a * 'o option) Build.t

  val forbid : (unit -> 'a Build.t) -> 'a Build.t

  module type Implicit_output = sig
    type t

    val name : string

    val union : t -> t -> t
  end

  (** Register a new type of implicit output. *)
  val add : (module Implicit_output with type t = 'o) -> 'o t
end

module With_implicit_output : sig
  type ('i, 'o) t

  val create :
       string
    -> ?doc:string
    -> input:(module Input with type t = 'i)
    -> visibility:'i Visibility.t
    -> output:(module Output_simple with type t = 'o)
    -> implicit_output:'io Implicit_output.t
    -> ('i -> 'o Build.t)
    -> ('i, 'o) t

  val exec : ('i, 'o) t -> 'i -> 'o Build.t
end

module Cell : sig
  type ('i, 'o) t

  val input : ('i, _) t -> 'i

  val read : (_, 'o) t -> 'o Build.t

  (** Mark this cell as invalid, forcing recomputation of this value. The
      consumers may be recomputed or not, depending on early cutoff. *)
  val invalidate : _ t -> unit
end

(** Create a "memoization cell" that focuses on a single input/output pair of a
    memoized function. *)
val cell : ('i, 'o) t -> 'i -> ('i, 'o) Cell.t

module Expert : sig
  (** Like [cell] but returns [Nothing] if the given memoized function has never
      been evaluated on the specified input. We use [previously_evaluated_cell]
      to skip unnecessary rebuilds when receiving file system events for files
      that we don't care about.

      Note that this function is monotonic: its result can change from [Nothing]
      to [Some cell] as new cells get evaluated. However, calling [reset] clears
      all memoization tables, and therefore resets [previously_evaluated_cell]
      to [Nothing] as well. *)
  val previously_evaluated_cell : ('i, 'o) t -> 'i -> ('i, 'o) Cell.t option
end

(** Memoization of polymorphic functions ['a input -> 'a output Build.t]. The
    provided [id] function must be injective, i.e. there must be a one-to-one
    correspondence between [input]s and their [id]s. *)
module Poly (Function : sig
  type 'a input

  type 'a output

  val name : string

  val eval : 'a input -> 'a output Build.t

  val to_dyn : _ input -> Dyn.t

  val id : 'a input -> 'a Type_eq.Id.t
end) : sig
  val eval : 'a Function.input -> 'a Function.output Build.t
end

val unwrap_exn : (exn -> exn) ref

(** If [true], this module will record the location of [Lazy.t] values. This is
    a bit expensive to compute, but it helps debugging. *)
val track_locations_of_lazy_values : bool ref
