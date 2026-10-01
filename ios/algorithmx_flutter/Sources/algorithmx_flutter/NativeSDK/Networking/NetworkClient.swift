//
//  NetworkClient.swift
//  AlgorithmXSDK
//
//  Network client for making HTTP requests
//

import Foundation

class NetworkClient {

    static let shared = NetworkClient()

    private init() {}

    // MARK: - POST Request
    func postJson(
        endpoint: String, payload: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let url = URL(string: endpoint) else {
            completion(
                .failure(
                    NSError(
                        domain: "AlgorithmX", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                SdkLog.error("POST \(endpoint) failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            SdkLog.debug("POST status=\(status) url=\(endpoint)")

            guard let data = data else {
                completion(
                    .failure(
                        NSError(
                            domain: "AlgorithmX", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    completion(.success(json))
                } else {
                    completion(.success([:]))
                }
            } catch {
                // If response is not JSON, consider it success anyway (204, etc.)
                completion(.success([:]))
            }
        }.resume()
    }

    // MARK: - PUT Request
    func putJson(
        endpoint: String, payload: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let url = URL(string: endpoint) else {
            completion(
                .failure(
                    NSError(
                        domain: "AlgorithmX", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                SdkLog.error("PUT \(endpoint) failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            SdkLog.debug("PUT status=\((response as? HTTPURLResponse)?.statusCode ?? -1) url=\(endpoint)")

            guard let data = data else {
                completion(
                    .failure(
                        NSError(
                            domain: "AlgorithmX", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    completion(.success(json))
                } else {
                    completion(.success([:]))
                }
            } catch {
                completion(.success([:]))
            }
        }.resume()
    }

    // MARK: - GET Request
    func getJson(endpoint: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: endpoint) else {
            completion(
                .failure(
                    NSError(
                        domain: "AlgorithmX", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                SdkLog.error("GET \(endpoint) failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(
                    .failure(
                        NSError(
                            domain: "AlgorithmX", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    completion(.success(json))
                } else {
                    completion(.success([:]))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
