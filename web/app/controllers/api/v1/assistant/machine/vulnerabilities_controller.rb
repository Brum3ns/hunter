module Api
  module V1
    module Assistant
      module Machine
        # Read-only, grant-and-scope-gated vulnerability browsing for the
        # Assistant. Delegates to Vulnerabilities::MongoSource and returns
        # only the bounded VulnerabilityProjection allowlist — the hard
        # secret-exclusion boundary (raw request/response HTTP, poc curl/
        # extracted/llm_reasoning, operator PII) lives in that projection.
        class VulnerabilitiesController < ReadController
          MAX_LIMIT = 50
          FILTERS = %i[program severity status tool].freeze

          def index
            reservation = authorize_tool!("list_vulnerabilities", scope: "vulnerabilities_read")
            filters = params.permit(*FILTERS).to_h
            search = params[:q].presence
            page = machine_page
            limit = machine_limit(MAX_LIMIT)
            count = ::Vulnerabilities::MongoSource.count(filters: filters, search: search)
            items = ::Vulnerabilities::MongoSource.all(filters: filters, search: search, page: page, limit: limit)
                                                   .map { |doc| ::Assistant::Machine::VulnerabilityProjection.summary(::Vulnerability.new(doc)) }
            list_response(reservation, count: count, page: page, limit: limit, items: items)
          end

          def show
            reservation = authorize_tool!("get_vulnerability", scope: "vulnerabilities_read")
            doc = ::Vulnerabilities::MongoSource.find(params[:id])
            return machine_not_found(reservation) unless doc

            detail_response(reservation, key: :vulnerability, value: ::Assistant::Machine::VulnerabilityProjection.full(::Vulnerability.new(doc)))
          end

          def analyze
            reservation = authorize_tool!("analyze_vulnerabilities", scope: "vulnerabilities_read")
            body = exact_machine_body(reservation, [ "q", *FILTERS.map(&:to_s) ])
            return unless body

            filters = body.except("q")
            count = ::Vulnerabilities::MongoSource.count(filters: filters, search: body["q"].presence)
            docs = ::Vulnerabilities::MongoSource.all(
              filters: filters, search: body["q"].presence, page: 1,
              limit: ::Assistant::Machine::WorkflowAnalysis::MAX_ROWS
            )
            payload = ::Assistant::Machine::WorkflowAnalysis.vulnerabilities(
              docs.map { |doc| ::Vulnerability.new(doc) }, count: count
            )
            complete_read_response!(reservation,
              { correlation_id: machine_grant.turn.correlation_id }.merge(payload))
          end

          def create
            tool = "create_vulnerability"
            reservation = authorize_tool!(tool, scope: "vulnerabilities_create")
            body = exact_machine_body(reservation, %w[vulnerability])
            return unless body
            input = ::Assistant::Machine::VulnerabilityInput.call(
              body["vulnerability"], user: machine_user, require_name: true
            )
            return render_machine_validation_error(reservation, input.codes) unless input.success?

            idempotency_key = machine_idempotency_key(tool, body.fetch("vulnerability"))
            return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
            return unless consume_machine_effect!(reservation)

            id = ::Vulnerabilities::MongoSource.create(input.create_attributes)
            receipt = issue_machine_receipt(
              tool: tool, status: "created", target_type: "vulnerability",
              target_id: id, idempotency_key: idempotency_key
            )
            complete_machine_effect!(reservation, receipt: receipt, status: :created)
          end

          def update
            tool = "update_vulnerability"
            reservation = authorize_tool!(tool, scope: "vulnerabilities_update")
            body = exact_machine_body(reservation, %w[expected_version vulnerability])
            return unless body
            expected = body["expected_version"]
            unless expected.is_a?(String) && expected.present? && expected.bytesize <= 255
              return render_machine_validation_error(reservation, [ "assistant_expected_version_invalid" ])
            end
            input = ::Assistant::Machine::VulnerabilityInput.call(
              body["vulnerability"], user: machine_user, require_name: false
            )
            return render_machine_validation_error(reservation, input.codes) unless input.success?

            normalized = { "id" => params[:id].to_s, "expected_version" => expected,
              "vulnerability" => body.fetch("vulnerability") }
            idempotency_key = machine_idempotency_key(tool, normalized)
            return if replay_machine_action(reservation, tool: tool, idempotency_key: idempotency_key)
            return unless consume_machine_effect!(reservation)

            result = ::Vulnerabilities::MongoSource.update_with_version(
              id: params[:id], expected_version: expected, attrs: input.update_attributes
            )
            if result.status == :not_found
              reservation.fail!
              return render json: { error: "not_found" }, status: :not_found
            end
            if result.status == :conflict
              reservation.fail!
              return render json: { error: "version_conflict" }, status: :conflict
            end

            receipt = issue_machine_receipt(
              tool: tool, status: "updated", target_type: "vulnerability",
              target_id: params[:id], idempotency_key: idempotency_key
            )
            complete_machine_effect!(reservation, receipt: receipt)
          end
        end
      end
    end
  end
end
